"""Billing for Quill Cloud: plans, proration, coupons, VAT, invoices and payment retries."""
import decimal
import datetime
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Dict, List, Optional, Set, Tuple, Union
from decimal import Decimal, ROUND_HALF_UP

class Plan(Enum):
    FREE = auto()
    PRO = auto()
    TEAM = auto()

class Currency(Enum):
    USD = auto()
    EUR = auto()
    PLN = auto()

class InvoiceStatus(Enum):
    DRAFT = auto()
    SENT = auto()
    PAID = auto()
    FAILED = auto()
    CANCELLED = auto()

@dataclass
class Customer:
    id: str
    name: str
    email: str
    country: str
    vat_id: Optional[str] = None
    currency: Currency = Currency.USD
    plan: Plan = Plan.FREE
    plan_start_date: datetime.date = field(default_factory=datetime.date.today)
    trial_end_date: Optional[datetime.date] = None
    payment_failed_retries: int = 0
    last_payment_failure: Optional[datetime.datetime] = None
    team_seats: int = 1
    coupon_code: Optional[str] = None

@dataclass
class Subscription:
    customer_id: str
    plan: Plan
    start_date: datetime.date
    end_date: Optional[datetime.date] = None
    team_seats: int = 1
    coupon_code: Optional[str] = None

@dataclass
class LineItem:
    description: str
    quantity: Decimal
    unit_price: Decimal
    amount: Decimal
    tax_rate: Decimal = Decimal('0')
    tax_amount: Decimal = Decimal('0')

@dataclass
class Invoice:
    id: str
    customer_id: str
    status: InvoiceStatus
    issue_date: datetime.date
    due_date: datetime.date
    line_items: List[LineItem]
    subtotal: Decimal = Decimal('0')
    tax_total: Decimal = Decimal('0')
    total: Decimal = Decimal('0')
    currency: Currency = Currency.USD
    country: str = ""
    vat_id: Optional[str] = None
    payment_attempts: int = 0
    last_payment_attempt: Optional[datetime.datetime] = None

@dataclass
class Coupon:
    code: str
    discount_type: str  # 'percent' or 'fixed'
    discount_value: Decimal
    max_redemptions: Optional[int] = None
    redemptions: int = 0
    expiry_date: Optional[datetime.date] = None

@dataclass
class TaxRule:
    country: str
    rate: Decimal
    is_reverse_charge: bool = False

def round_money(amount: Decimal) -> Decimal:
    """Round to 2 decimal places, half up (invoice amounts)."""
    return amount.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)


class Pricing:
    PLAN_PRICES = {
        Plan.FREE: {
            Currency.USD: Decimal('0'),
            Currency.EUR: Decimal('0'),
            Currency.PLN: Decimal('0')
        },
        Plan.PRO: {
            Currency.USD: Decimal('19.99'),
            Currency.EUR: Decimal('17.99'),
            Currency.PLN: Decimal('89.99')
        },
        Plan.TEAM: {
            Currency.USD: Decimal('49.99'),
            Currency.EUR: Decimal('44.99'),
            Currency.PLN: Decimal('229.99')
        }
    }

    ADDON_PRICES = {
        Currency.USD: Decimal('9.99'),
        Currency.EUR: Decimal('8.99'),
        Currency.PLN: Decimal('44.99')
    }

    @classmethod
    def get_plan_price(cls, plan: Plan, currency: Currency) -> Decimal:
        return cls.PLAN_PRICES[plan][currency]

    @classmethod
    def get_addon_price(cls, currency: Currency) -> Decimal:
        return cls.ADDON_PRICES[currency]

class BillingCalculator:
    @staticmethod
    def calculate_prorated_amount(
        plan: Plan,
        currency: Currency,
        start_date: datetime.date,
        end_date: datetime.date,
        cycle_start: datetime.date,
        cycle_end: datetime.date
    ) -> Decimal:
        """Calculate prorated amount for plan change mid-cycle."""
        total_days = (cycle_end - cycle_start).days
        if total_days <= 0:
            return Decimal('0')

        days_used = (end_date - start_date).days
        if days_used <= 0:
            return Decimal('0')

        base_price = Pricing.get_plan_price(plan, currency)
        daily_rate = base_price / Decimal(total_days)
        return round_money(daily_rate * Decimal(days_used))

    @staticmethod
    def apply_coupon(
        amount: Decimal,
        coupon: Coupon,
        currency: Currency
    ) -> Tuple[Decimal, Decimal]:
        """Apply coupon and return (discount_amount, remaining_amount)."""
        if coupon.expiry_date and coupon.expiry_date > datetime.date.today():
            return Decimal('0'), amount

        if coupon.discount_type == 'percent':
            discount = amount * (coupon.discount_value / Decimal('100'))
        elif coupon.discount_type == 'fixed':
            discount = coupon.discount_value
        else:
            raise ValueError("Invalid coupon discount type")

        discount = round_money(min(discount, amount))
        return discount, amount - discount

    @staticmethod
    def calculate_tax(
        amount: Decimal,
        country: str,
        vat_id: Optional[str],
        tax_rules: List[TaxRule]
    ) -> Tuple[Decimal, Decimal]:
        """Calculate tax amount and return (tax_amount, total_amount)."""
        tax_rule = next((r for r in tax_rules if r.country == country), None)
        if not tax_rule:
            return Decimal('0'), amount

        if vat_id or tax_rule.is_reverse_charge:
            return Decimal('0'), amount

        tax_amount = round_money(amount * tax_rule.rate / Decimal('100'))
        return tax_amount, amount + tax_amount

    @staticmethod
    def calculate_team_addon(
        seats: int,
        currency: Currency,
        start_date: datetime.date,
        end_date: datetime.date
    ) -> Decimal:
        """Calculate addon for team seats above 5."""
        if seats <= 5:
            return Decimal('0')

        extra_seats = seats - 5
        days_in_period = (end_date - start_date).days
        if days_in_period <= 0:
            return Decimal('0')

        daily_rate = Pricing.get_addon_price(currency) / Decimal('30')
        return round_money(daily_rate * Decimal(extra_seats) * Decimal(days_in_period))

    @staticmethod
    def should_retry_payment(
        invoice: Invoice,
        now: datetime.datetime
    ) -> bool:
        """Determine if payment should be retried with exponential backoff."""
        if invoice.payment_attempts > 3:
            return False

        if invoice.last_payment_attempt is None:
            return True

        hours_since_last_attempt = (now - invoice.last_payment_attempt).total_seconds() / 3600
        backoff_hours = 2 ** invoice.payment_attempts

        return hours_since_last_attempt >= backoff_hours

class InvoiceRepository:
    def __init__(self):
        self._invoices: Dict[str, Invoice] = {}
        self._customer_invoices: Dict[str, Set[str]] = {}
        self._status_invoices: Dict[InvoiceStatus, Set[str]] = {}

    def add_invoice(self, invoice: Invoice) -> None:
        self._invoices[invoice.id] = invoice

        if invoice.customer_id not in self._customer_invoices:
            self._customer_invoices[invoice.customer_id] = set()
        self._customer_invoices[invoice.customer_id].add(invoice.id)

        if invoice.status not in self._status_invoices:
            self._status_invoices[invoice.status] = set()
        self._status_invoices[invoice.status].add(invoice.id)

    def get_invoice(self, invoice_id: str) -> Optional[Invoice]:
        return self._invoices.get(invoice_id)

    def get_invoices_by_customer(self, customer_id: str) -> List[Invoice]:
        invoice_ids = self._customer_invoices.get(customer_id, set())
        return [self._invoices[i] for i in invoice_ids]

    def get_invoices_by_status(self, status: InvoiceStatus) -> List[Invoice]:
        invoice_ids = self._status_invoices.get(status, set())
        return [self._invoices[i] for i in invoice_ids]

    def update_invoice_status(self, invoice_id: str, new_status: InvoiceStatus) -> None:
        if invoice_id not in self._invoices:
            return

        old_status = self._invoices[invoice_id].status
        if old_status == new_status:
            return

        self._invoices[invoice_id].status = new_status
        if new_status not in self._status_invoices:
            self._status_invoices[new_status] = set()
        self._status_invoices[new_status].add(invoice_id)

class BillingService:
    def __init__(self):
        self.invoice_repo = InvoiceRepository()
        self.tax_rules = [
            TaxRule("US", Decimal('0')),  # No VAT for US customers
            TaxRule("DE", Decimal('19'), is_reverse_charge=True),  # Germany 19%, B2B reverse charge
            TaxRule("FR", Decimal('20'), is_reverse_charge=True),  # France 20%, B2B reverse charge
            TaxRule("PL", Decimal('23'), is_reverse_charge=True),  # Poland 23%, B2B reverse charge
            TaxRule("IT", Decimal('22'), is_reverse_charge=True),  # Italy 22%, B2B reverse charge
        ]
        self.coupons: Dict[str, Coupon] = {}

    def add_coupon(self, coupon: Coupon) -> None:
        self.coupons[coupon.code] = coupon

    def get_coupon(self, code: str) -> Optional[Coupon]:
        return self.coupons.get(code)

    def generate_monthly_invoices(
        self,
        customers: List[Customer],
        today: datetime.date
    ) -> List[Invoice]:
        invoices = []
        for customer in customers:
            if customer.plan == Plan.FREE:
                continue

            # Check if trial is still active
            if customer.trial_end_date and today <= customer.trial_end_date:
                continue

            # Check if we already generated this month's invoice
            existing_invoices = self.invoice_repo.get_invoices_by_customer(customer.id)
            if any(i.issue_date.month == today.month and i.issue_date.year == today.year
                   for i in existing_invoices):
                continue

            # Calculate subscription amount
            plan_price = Pricing.get_plan_price(customer.plan, customer.currency)
            addon_amount = BillingCalculator.calculate_team_addon(
                customer.team_seats if customer.plan == Plan.TEAM else 0,
                customer.currency,
                customer.plan_start_date,
                today
            )
            subtotal = plan_price + addon_amount

            # Apply coupon if available
            coupon = None
            discount = Decimal('0')
            if customer.coupon_code:
                coupon = self.get_coupon(customer.coupon_code)
                if coupon and (coupon.max_redemptions is None or coupon.redemptions < coupon.max_redemptions):
                    discount, subtotal = BillingCalculator.apply_coupon(subtotal, coupon, customer.currency)
                else:
                    coupon = None

            # Calculate tax
            tax_amount, total = BillingCalculator.calculate_tax(
                subtotal,
                customer.country,
                customer.vat_id,
                self.tax_rules
            )

            # Create line items
            line_items = [
                LineItem(
                    description=f"{customer.plan.name} Plan",
                    quantity=Decimal('1'),
                    unit_price=plan_price,
                    amount=plan_price
                )
            ]

            if addon_amount > Decimal('0'):
                line_items.append(
                    LineItem(
                        description=f"Team Addon ({customer.team_seats - 5} seats)",
                        quantity=Decimal(customer.team_seats - 5),
                        unit_price=Pricing.get_addon_price(customer.currency),
                        amount=addon_amount
                    )
                )

            if coupon and discount > Decimal('0'):
                line_items.append(
                    LineItem(
                        description=f"Coupon {coupon.code}",
                        quantity=Decimal('1'),
                        unit_price=-discount,
                        amount=-discount
                    )
                )

            # Create invoice
            invoice = Invoice(
                id=f"INV-{customer.id}-{today.strftime('%Y%m')}",
                customer_id=customer.id,
                status=InvoiceStatus.DRAFT,
                issue_date=today,
                due_date=today + datetime.timedelta(days=14),
                line_items=line_items,
                subtotal=subtotal,
                tax_total=tax_amount,
                total=total,
                currency=customer.currency,
                country=customer.country,
                vat_id=customer.vat_id
            )

            invoices.append(invoice)
            self.invoice_repo.add_invoice(invoice)

            # Update coupon redemptions if applied
            if coupon:
                coupon.redemptions += 1

        return invoices

    def format_currency(self, amount: Decimal, currency: Currency) -> str:
        """Format amount with currency symbol."""
        symbols = {
            Currency.USD: "$",
            Currency.EUR: "€",
            Currency.PLN: "zł"
        }
        return f"{symbols[currency]}{amount.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)}"

    def calculate_invoice_totals(self, invoice: Invoice) -> Tuple[Decimal, Decimal, Decimal]:
        """Recalculate invoice totals (subtotal, tax, total)."""
        subtotal = sum(item.amount for item in invoice.line_items)
        tax_amount, total = BillingCalculator.calculate_tax(
            subtotal,
            invoice.country,
            invoice.vat_id,
            self.tax_rules
        )
        return subtotal, tax_amount, total

    def handle_payment_failure(self, invoice_id: str, now: datetime.datetime) -> bool:
        """Handle payment failure and determine if retry is needed."""
        invoice = self.invoice_repo.get_invoice(invoice_id)
        if not invoice:
            return False

        invoice.payment_attempts += 1
        invoice.last_payment_attempt = now

        if BillingCalculator.should_retry_payment(invoice, now):
            return True

        self.invoice_repo.update_invoice_status(invoice_id, InvoiceStatus.FAILED)
        return False
