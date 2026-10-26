/// Config z kilkoma dostawcami chmurowymi (dawny domyślny) do testów routingu i parsowania.
let sampleConfigToml = #"""
# Kolejność [[provider]] = priorytet fallbacku. ID modeli często się zmieniają;
# użyj list_remote_models, żeby sprawdzić aktualne.

routing_guidance = """
Deleguj zadania samowystarczalne: masowe generowanie, tłumaczenia, pierwsze drafty,
streszczenia wklejonego tekstu, druga opinia o fragmencie kodu.
Wynik zawsze weryfikuj. Nie wysyłaj danych z pracy, sekretów ani danych osobowych.
Do DeepSeeka nie wysyłaj niczego prywatnego (dane przetwarzane w Chinach).
"""

timeout_seconds = 120

[[provider]]
id = "mistral"
type = "openai"
base_url = "https://api.mistral.ai/v1"
api_key_env = "MISTRAL_API_KEY"
note = "Za darmo tylko na planie Experiment w Mistral Studio; darmowy plan może pozwalać na użycie danych."

[[provider.model]]
id = "mistral-small-latest"
tags = ["general", "translate", "summarize"]
cost = "free"

[[provider.model]]
id = "codestral-latest"
tags = ["code"]
cost = "free"

[[provider]]
id = "gemini"
type = "gemini"
base_url = "https://generativelanguage.googleapis.com/v1beta"
api_key_env = "GEMINI_API_KEY"
note = "Free tier zwykle pozwala dostawcy używać przesłanych danych."

[[provider.model]]
id = "gemini-flash-latest"
tags = ["general", "translate", "summarize", "long-context"]
cost = "free"

[[provider.model]]
id = "gemini-pro-latest"
tags = ["reasoning", "code"]
cost = "paid"

[[provider]]
id = "deepseek"
type = "openai"
base_url = "https://api.deepseek.com/v1"
api_key_env = "DEEPSEEK_API_KEY"
note = "Dane przetwarzane w Chinach. Nie wysyłaj niczego z pracy."

[[provider.model]]
id = "deepseek-chat"
tags = ["general", "code"]
cost = "cheap"

[[provider.model]]
id = "deepseek-reasoner"
tags = ["reasoning"]
cost = "cheap"

[[provider]]
id = "openrouter"
type = "openai"
base_url = "https://openrouter.ai/api/v1"
api_key_env = "OPENROUTER_API_KEY"

[[provider.model]]
id = "openrouter/auto"
tags = ["general"]
cost = "varies"

[[provider]]
id = "apple"
type = "foundation"
note = "Model na urządzeniu (Apple Intelligence): za darmo, prywatnie, offline. Małe okno kontekstu, tylko krótkie zadania."

[[provider.model]]
id = "on-device"
tags = ["private", "short", "offline"]
cost = "free"
"""#
