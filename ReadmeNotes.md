### Smart Test Ordering

Endpoints are automatically ordered based on path patterns and HTTP method so that create operations run before reads, updates, and deletes.

| Pattern | Priority |
|---|---|
| `*/register*` | 1st |
| `*/login*` | 2nd |
| `*/create*` | 3rd |
| `*/add*` | 4th |
| `*/update*` | 5th |
| `*/remove*` | 6th |
| `*/delete*` | 7th |
| everything else | last |

Within each group, methods run in order: `POST → GET → PUT → DELETE`.