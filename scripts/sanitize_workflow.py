#!/usr/bin/env python3
"""Limpia un workflow exportado de n8n antes de publicarlo.

Quita todo lo que esta atado a la instancia de origen o que es dato personal:
  - IDs de credenciales (se deja solo un nombre generico por tipo)
  - pinData (datos de ejecuciones de prueba)
  - IDs del workflow, del Error Workflow y de sub-workflows
  - IDs/URLs de Google Sheets y Data Tables
  - chat IDs de Telegram escritos a mano

Uso:
    python3 scripts/sanitize_workflow.py entrada.json salida.json
"""
import json
import re
import sys

CREDENTIAL_NAMES = {
    "gmailOAuth2": "Gmail",
    "googleSheetsOAuth2Api": "Google Sheets",
    "googlePalmApi": "Google Gemini",
    "groqApi": "Groq",
    "deepSeekApi": "DeepSeek",
    "telegramApi": "Telegram Bot",
    "postgres": "Postgres",
}

# Correos dentro de nombres de nodo (p. ej. "Gmail alguien@gmail.com")
EMAIL_IN_NAME = re.compile(r"\s*[\w.+-]+@[\w-]+\.[\w.]+")

TELEGRAM_CHAT_PLACEHOLDER = "TU_CHAT_ID_DE_TELEGRAM"


def clean_resource_locator(rl):
    """Vacia un resource locator (__rl) conservando el nombre como referencia."""
    rl = dict(rl)
    rl.pop("cachedResultUrl", None)
    rl["value"] = ""
    return rl


def clean_node(node):
    params = node.get("parameters", {})

    # Credenciales: sin ID, con nombre generico
    if "credentials" in node:
        node["credentials"] = {
            ctype: {"name": CREDENTIAL_NAMES.get(ctype, ctype)}
            for ctype in node["credentials"]
        }

    # Google Sheets / Data Tables / sub-workflows
    for key in ("documentId", "dataTableId", "workflowId"):
        if isinstance(params.get(key), dict) and params[key].get("__rl"):
            params[key] = clean_resource_locator(params[key])
    if isinstance(params.get("sheetName"), dict):
        params["sheetName"].pop("cachedResultUrl", None)

    # chat ID de Telegram escrito a mano (no expresiones)
    chat_id = params.get("chatId")
    if isinstance(chat_id, str) and re.fullmatch(r"-?\d+", chat_id):
        params["chatId"] = TELEGRAM_CHAT_PLACEHOLDER

    return node


def sanitize(workflow):
    # Renombrar nodos cuyo nombre incluye un correo; el reemplazo se hace sobre
    # todo el JSON para actualizar tambien conexiones y expresiones $('...')
    text = json.dumps(workflow, ensure_ascii=False)
    for node in workflow["nodes"]:
        new_name = EMAIL_IN_NAME.sub("", node["name"])
        if new_name != node["name"]:
            text = text.replace(node["name"], f"{new_name} Trigger"
                                if node["type"].endswith("Trigger") else new_name)
    workflow = json.loads(text)

    workflow["nodes"] = [clean_node(n) for n in workflow["nodes"]]
    workflow["pinData"] = {}
    workflow["active"] = False
    for key in ("id", "meta", "versionId", "shared", "triggerCount"):
        workflow.pop(key, None)
    workflow.get("settings", {}).pop("errorWorkflow", None)
    return workflow


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        workflow = json.load(f)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(sanitize(workflow), f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
