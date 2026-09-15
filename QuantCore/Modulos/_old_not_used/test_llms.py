import os
import time
import json
import sys
from dotenv import load_dotenv
load_dotenv(r'C:\ALXQuant\.env', override=True)

try:
    import litellm
except ImportError:
    print("litellm nao instalado. Execute: pip install litellm --only-binary litellm")
    exit(1)

import urllib.request
import urllib.error

PROVIDERS = [
    {
        "name": "Groq",
        "model": "groq/llama-3.3-70b-versatile",
        "api_key": os.getenv("GROQ_API_KEY", ""),
        "env_var": "GROQ_API_KEY",
    },
    {
        "name": "Z.AI (OpenAI)",
        "model": "openai/gpt-4o-mini",
        "api_key": os.getenv("OPENAI_API_KEY", ""),
        "env_var": "OPENAI_API_KEY",
        "api_base": "https://api.zai.chat/v1",
    },
    {
        "name": "OpenRouter",
        "model": "openrouter/anthropic/claude-3-haiku",
        "api_key": os.getenv("OPENROUTER_API_KEY", ""),
        "env_var": "OPENROUTER_API_KEY",
        "api_base": "https://openrouter.ai/api/v1",
    },
    {
        "name": "Gemini",
        "model": "gemini/gemini-2.0-flash",
        "api_key": os.getenv("GEMINI_API_KEY", ""),
        "env_var": "GEMINI_API_KEY",
    },
    {
        "name": "DashScope (Qwen)",
        "model": "dashscope/qwen-max",
        "api_key": os.getenv("DASHSCOPE_API_KEY", ""),
        "env_var": "DASHSCOPE_API_KEY",
        "api_base": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    },
    {
        "name": "DeepSeek",
        "model": "deepseek/deepseek-chat",
        "api_key": os.getenv("DEEPSEEK_API_KEY", ""),
        "env_var": "DEEPSEEK_API_KEY",
        "api_base": "https://api.deepseek.com",
    },
    {
        "name": "Together AI",
        "model": "together_ai/mistralai/Mixtral-8x7B-Instruct-v0.1",
        "api_key": os.getenv("TOGETHER_API_KEY", ""),
        "env_var": "TOGETHER_API_KEY",
    },
    {
        "name": "Perplexity",
        "model": "perplexity/llama-3-sonar-small-32k-chat",
        "api_key": os.getenv("PERPLEXITY_API_KEY", ""),
        "env_var": "PERPLEXITY_API_KEY",
    },
    {
        "name": "Fireworks AI",
        "model": "fireworks_ai/accounts/fireworks/models/llama-v3p1-8b-instruct",
        "api_key": os.getenv("FIREWORKS_API_KEY", ""),
        "env_var": "FIREWORKS_API_KEY",
    },
    {
        "name": "Anthropic",
        "model": "anthropic/claude-3-haiku-20240307",
        "api_key": os.getenv("ANTHROPIC_API_KEY", ""),
        "env_var": "ANTHROPIC_API_KEY",
    },
    {
        "name": "Ollama (local)",
        "model": "ollama/llama3.2",
        "api_key": "ollama",
        "api_base": "http://localhost:11434",
    },
]

def test_direct_http(name, api_key, api_base, model):
    """Testa a chave via HTTP direto (sem litellm)"""
    if not api_key or not api_base:
        return None

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    # Mapeia endpoint /chat/completions
    urls_to_try = [
        f"{api_base.rstrip('/')}/chat/completions",
        f"{api_base.rstrip('/')}/v1/chat/completions",
    ]

    body = json.dumps({
        "model": model.split("/")[-1] if "/" in model else model,
        "messages": [{"role": "user", "content": "OK"}],
        "max_tokens": 5,
    }).encode()

    for url in urls_to_try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
                content = data["choices"][0]["message"]["content"].strip()
                return f"HTTP OK: {content}"
        except urllib.error.HTTPError as e:
            err_body = e.read().decode()
            return f"HTTP {e.code}: {err_body[:100]}"
        except Exception:
            continue
    return None


SEP = "=" * 72
DASH = "-" * 72
print(SEP)
print("TESTE COMPLETO DE PROVEDORES LLM")
print(SEP)

results = []
for p in PROVIDERS:
    name = p["name"]
    model = p["model"]
    key = p["api_key"]
    base = p.get("api_base", "")
    env_var = p.get("env_var", "")

    print(f"\n{DASH}")
    print(f"  {name}")
    print(f"  Modelo: {model}")
    print(f"  Env var: {env_var}")
    print(f"  Key: {key[:12]}...{key[-4:] if len(key) > 16 else '(sem)'}")
    print(f"  URL: {base or '(padrao litellm)'}")
    print(DASH)

    if not key and base != "http://localhost:11434":
        print("  >>> SKIP: sem chave")
        results.append((name, "SKIP", 0))
        continue

    # Seta env var padronizada
    if env_var:
        os.environ[env_var] = key

    # 1) Teste via HTTP direto primeiro
    http_result = test_direct_http(name, key, base, model)
    if http_result:
        print(f"  [HTTP] {http_result}")
    elif base:
        print(f"  [HTTP] Sem resposta (pode ser normal, litellm pode usar endpoint diferente)")

    # 2) Teste via litellm
    kwargs = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Responda exatamente uma palavra: OK"},
            {"role": "user", "content": "Responda: OK"},
        ],
        "max_tokens": 5,
        "temperature": 0,
    }
    if key:
        kwargs["api_key"] = key
    if base:
        kwargs["api_base"] = base

    start = time.time()
    try:
        resp = litellm.completion(**kwargs)
        elapsed = time.time() - start
        content = resp.choices[0].message.content.strip()
        print(f"  [LITELLM] >>> OK ({elapsed:.1f}s): {repr(content)}")
        results.append((name, "OK", elapsed))
    except litellm.RateLimitError as e:
        elapsed = time.time() - start
        print(f"  [LITELLM] >>> RATE LIMIT ({elapsed:.1f}s): {str(e)[:100]}")
        results.append((name, "RATE LIMIT", elapsed))
    except litellm.AuthenticationError as e:
        elapsed = time.time() - start
        print(f"  [LITELLM] >>> AUTH ERROR ({elapsed:.1f}s): {str(e)[:100]}")
        results.append((name, "AUTH ERROR", elapsed))
    except Exception as e:
        elapsed = time.time() - start
        err = str(e).replace("\n", " ")[:120]
        print(f"  [LITELLM] >>> FALHA ({elapsed:.1f}s): {err}")
        results.append((name, "FALHA", elapsed))

# Sumario final
print(f"\n{SEP}")
print("RESUMO")
print(SEP)
print(f"{'Provedor':<25} {'Status':<15} {'Tempo':<10}")
print("-" * 50)
for name, status, elapsed in results:
    print(f"{name:<25} {status:<15} {elapsed:<10.1f}s")
print(SEP)
