# secrets/

Put the two BigQuery service-account keys here. Everything in this folder
except this README is git-ignored.

| File | Service account | Roles |
|---|---|---|
| `bq-writer.json` | `n8n-writer` | BigQuery Data Editor + BigQuery Job User |
| `bq-analyst.json` | `n8n-analyst` | BigQuery Data Viewer + BigQuery Job User |

See `docs/SETUP.md`, step 4.
