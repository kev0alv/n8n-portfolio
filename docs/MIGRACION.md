# Migración: del servidor de Kodigo a tu propio n8n

Los `.json` de `workflows/` están sanitizados. Importan sin errores, pero antes de activarlos hay que reconectar cuatro cosas: **credenciales**, **hojas de Google Sheets**, **referencias entre workflows** y algunos **IDs propios de tus cuentas**.

## 1. Levantar n8n

```bash
cp .env.example .env
# Edita .env: contraseña de Postgres y N8N_ENCRYPTION_KEY (openssl rand -hex 32)
docker compose up -d
```

Abre `http://localhost:5678` y crea tu usuario dueño.

> Para usar los triggers de Telegram y los webhooks públicos (Lovable), n8n debe ser accesible desde internet con HTTPS: un VPS con dominio, n8n Cloud o un túnel (por ejemplo `cloudflared`). Ajusta `N8N_HOST`, `N8N_PROTOCOL` y `WEBHOOK_URL` en `.env`.

## 2. Crear las credenciales

En **Credentials → Add credential**, crea estas credenciales con tus propias cuentas. Si les pones exactamente estos nombres, n8n las sugiere al abrir cada nodo.

| Nombre | Tipo en n8n | Dónde se obtiene |
|---|---|---|
| `Gmail` | Gmail OAuth2 | Google Cloud Console → OAuth client |
| `Google Sheets` | Google Sheets OAuth2 | Mismo OAuth client de Google |
| `Google Gemini` | Google Gemini (PaLM) API | aistudio.google.com → API key |
| `Groq` | Groq | console.groq.com → API keys |
| `DeepSeek` | DeepSeek | platform.deepseek.com |
| `Telegram Bot` | Telegram API | @BotFather → token del bot |
| `Postgres` | Postgres | Tu base de datos (Supabase, Neon o el Postgres local) |

## 3. Importar en este orden

Algunos workflows llaman a otros, así que importa primero los que son llamados:

1. `05-alertas-y-notificaciones/Workflow_AlertasTelegram.json` — Error Workflow global
2. `03-clasificador-correos-ia/Workflow_ErroresMetricas_ClasificaCorreos.json`
3. `01-agente-djanne-escalamiento/Djanne_Metricas_Sheets.json` — sub-workflow de métricas
4. `01-agente-djanne-escalamiento/Djanne_ErroresMetricas.json`
5. El resto

## 4. Qué reconectar en cada workflow

| Workflow | Credenciales | Además… |
|---|---|---|
| **Djanne_Escalamiento** | DeepSeek, Gemini, Groq, Postgres, Telegram | `Registrar_Metrica` → elegir *Djanne_Metricas_Sheets*. Settings → Error Workflow → *Djanne_ErroresMetricas* |
| **Djanne_ErroresMetricas** | Telegram | `Alerta Guardia` → tu chat ID. `Registrar Metrica` → *Djanne_Metricas_Sheets* |
| **Djanne_Metricas_Sheets** | Google Sheets | `Registrar en Sheets` → tu hoja de métricas (pestaña `Ejecuciones`) |
| **AgenteConversacional_Memoria** / **Djenny_Esteroides** | Gemini, Groq, Postgres, Telegram | Settings → Error Workflow → *Workflow_AlertasTelegram* |
| **Clasifica_Correos_Linea_Base** | Gmail, Google Sheets, Groq | Labels de Gmail (ver punto 5). Hoja de métricas. Error Workflow → *Workflow_ErroresMetricas_ClasificaCorreos* |
| **Clasifica_Correos_Optimizado** | Gmail, Gemini, Google Sheets, Groq | Labels de Gmail (en `Etiquetar Correos` **y** en el código de `Calcular Metricas por Correo`). Hoja de métricas. Error Workflow |
| **Workflow_ErroresMetricas_ClasificaCorreos** | Google Sheets | Misma hoja de métricas del clasificador |
| **Flujo_Registro_Contacto** | Gmail, Google Sheets | Hoja *Registro de Aplicaciones*. Actualizar la URL del webhook en el formulario de Lovable |
| **Workflow_AlertasTelegram** | Google Sheets, Telegram | Chat ID. Crear la Data Table `Log_ErroresAlertasTG`. Hoja de respaldo |
| **ImportantEmail2TG_PushMessage** | Gmail, Google Sheets, Telegram | Chat ID. Hoja *RegistroMisImportantes* |
| **PruebaFallo** | — | Error Workflow → *Workflow_AlertasTelegram*. Corre cada 30 s: déjalo **inactivo** salvo para probar |
| **Asistente 1.0** | — | Usa los nodos de entrenamiento de n8n; funciona tal cual |
| **Registro_Usuarios_Nuevos** | Google Sheets | Hoja *Registro_Usuarios_Bootcamp* |

Los campos de hoja que quedaron vacíos conservan el nombre original de la hoja (`cachedResultName`) como pista.

## 5. IDs que dependen de tus cuentas

- **Chat ID de Telegram:** los nodos que decían tu ID ahora dicen `TU_CHAT_ID_DE_TELEGRAM`. Para obtener el tuyo, escríbele a tu bot y revisa la salida del nodo *Get ID only* en `ImportantEmail2TG_PushMessage`, o usa @userinfobot.
- **Labels de Gmail (`Label_…`):** cada cuenta tiene IDs distintos. Crea en Gmail las etiquetas INFORMACIÓN Y VENTAS, SOPORTE, RECLAMOS, OTROS y PROVEEDORES, y vuelve a elegirlas en los nodos. En el optimizado, el orden del arreglo de etiquetas **debe coincidir** con el orden de las categorías del clasificador.
- **Filtro de fecha del clasificador optimizado:** `Obtener Correos del Inbox` filtra `after:2026/09/07`. Ajústalo a tu caso.

## 6. Base de datos de los agentes Djanne/Djenny

Las herramientas de los agentes esperan estas tablas en Postgres: `catalogo`, `ventas`, `politicas_envio`, `politicas_devolucion` y `casos_soporte`. También un trigger que descuente el stock al registrar ventas, y la secuencia del número de ticket `FCF-000000`. La tabla de memoria `n8n_chat_histories` la crea n8n automáticamente.

El esquema SQL no forma parte de la exportación de n8n. Si lo tienes (por ejemplo en Supabase), agrégalo en `docs/schema.sql` para que el proyecto sea reproducible.

## 7. Exportar de nuevo sin filtrar datos

Cuando modifiques algo y quieras actualizar el repo:

```bash
# Descarga el workflow desde n8n (⋯ → Download) a exports/ (ignorado por git)
python3 scripts/sanitize_workflow.py exports/MiWorkflow.json workflows/<proyecto>/MiWorkflow.json
```
