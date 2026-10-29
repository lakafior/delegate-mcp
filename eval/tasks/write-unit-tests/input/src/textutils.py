import re
import unicodedata
from typing import List

def slugify(text: str, max_length: int = 60, separator: str = "-") -> str:
    """
    Convert text to a URL-friendly slug.

    Args:
        text: Input string to slugify.
        max_length: Maximum length of the output slug.
        separator: Character used to replace non-alphanumeric sequences.

    Returns:
        A lowercase slug with accents removed, non-alphanumeric sequences replaced by
        the separator, and leading/trailing separators removed. The result is truncated
        to max_length without leaving a trailing separator. Returns "" for empty input.
    """
    if not text:
        return ""

    # Normalize and remove accents
    normalized = unicodedata.normalize('NFKD', text)
    without_accents = ''.join(
        c for c in normalized
        if not unicodedata.combining(c)
    )

    # Replace ł/Ł with l
    without_accents = without_accents.replace('ł', 'l').replace('Ł', 'L')

    # Replace non-alphanumeric sequences with separator
    slug = re.sub(r'[^a-zA-Z0-9]+', separator, without_accents, flags=re.UNICODE)

    # Lowercase and strip separators
    slug = slug.lower().strip(separator)

    # Truncate to max_length without leaving a trailing separator
    if len(slug) > max_length:
        slug = slug[:max_length].rstrip(separator)

    return slug

def truncate(text: str, width: int, placeholder: str = "…") -> str:
    """
    Truncate text to fit within width, adding a placeholder if needed.

    Args:
        text: Input string to truncate.
        width: Maximum width of the output string.
        placeholder: String to append when truncating (default: "…").

    Returns:
        The original text if it fits within width, otherwise the text truncated at
        the last space before width - len(placeholder) (or hard-cut if no space),
        with the placeholder appended.

    Raises:
        ValueError: If width is less than the length of the placeholder.
    """
    if width < len(placeholder):
        raise ValueError("width must be at least the length of the placeholder")

    if len(text) <= width:
        return text

    truncate_len = width - len(placeholder)
    if truncate_len <= 0:
        return placeholder

    # Find the last space before truncate_len
    last_space = text.rfind(' ', 0, truncate_len)
    if last_space == -1:
        # No space found, hard cut
        return text[:truncate_len] + placeholder

    return text[:last_space] + placeholder

def parse_duration(value: str) -> int:
    """
    Parse a duration string into seconds.

    Args:
        value: Duration string like "1h30m", "45s", "2d", "1h 5m 10s", or "90".

    Returns:
        Total duration in seconds.

    Raises:
        ValueError: If the input is empty, contains unknown units, or has repeated units.
    """
    if not value.strip():
        raise ValueError("empty input")

    value = value.lower()
    pattern = r'^(\d+[dhms]\s*)+$'
    if not re.fullmatch(pattern, value + ' ', re.IGNORECASE):
        # Check for bare number (seconds)
        if value.isdigit():
            return int(value)
        raise ValueError("invalid duration format")

    units = {'d': 86400, 'h': 3600, 'm': 60, 's': 1}
    total = 0
    seen_units = set()

    for part in re.findall(r'(\d+)([dhms])', value):
        num, unit = part
        if unit in seen_units:
            raise ValueError(f"repeated unit '{unit}'")
        seen_units.add(unit)
        total += int(num) * units[unit]

    return total

def format_bytes(n: int, binary: bool = False) -> str:
    """
    Format a byte count into a human-readable string.

    Args:
        n: Number of bytes.
        binary: If True, use binary units (1024), otherwise use decimal units (1000).

    Returns:
        Human-readable string with one decimal place (or no decimals for bytes).

    Raises:
        ValueError: If n is negative.
    """
    if n < 0:
        raise ValueError("n must be non-negative")

    if binary:
        units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
        divisor = 1024
    else:
        units = ['B', 'kB', 'MB', 'GB', 'TB']
        divisor = 1000

    for unit in units:
        if n < divisor:
            if n % 1 == 0 and unit == 'B':
                return f"{n} {unit}"
            return f"{n:.1f} {unit}".rstrip('0').rstrip('.') if n < 10 else f"{n:.1f} {unit}"
        n /= divisor

    return f"{n:.1f} {units[-1]}"

def word_wrap(text: str, width: int) -> List[str]:
    """
    Wrap text to fit within a specified width.

    Args:
        text: Input text to wrap.
        width: Maximum width of each line.

    Returns:
        List of wrapped lines. Returns [] for empty input.

    Notes:
        - Greedy wrapping on spaces.
        - Words longer than width are split.
        - Collapses runs of whitespace.
    """
    if not text.strip():
        return []

    lines = []
    current_line = []
    current_length = 0

    # Collapse whitespace and split into words
    words = re.split(r'\s+', text.strip())

    for word in words:
        if not word:
            continue

        word_length = len(word)

        if word_length > width:
            # Split long words
            while word:
                if current_length + len(word) <= width:
                    current_line.append(word)
                    current_length += len(word)
                    break
                else:
                    split_pos = width - current_length
                    if split_pos <= 0:
                        lines.append(' '.join(current_line))
                        current_line = []
                        current_length = 0
                        continue
                    part = word[:split_pos]
                    current_line.append(part)
                    lines.append(' '.join(current_line))
                    current_line = []
                    current_length = 0
                    word = word[split_pos:]
        else:
            if current_length + len(current_line) + word_length <= width:
                current_line.append(word)
                current_length += word_length
            else:
                lines.append(' '.join(current_line))
                current_line = [word]
                current_length = word_length

    if current_line:
        lines.append(' '.join(current_line))

    return lines
