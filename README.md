# SmokeAlarm 
## PowerShell API Test Framework

A lightweight, OpenAPI-driven test framework for automatically generating and running simple API smoke tests from a Swagger/OpenAPI spec. 

### Advantages
- Simple to use, just put it in your pipeline, point it towards your api and spec and run it.
- Filterable (http methods, paths) and configurable (detailed errors, fail pipeline on error)

### Limitations

- Path parameters are replaced with `1` — real IDs are not resolved (yet, see upcoming features)
- Auth is Bearer token only
- Request bodies are best-effort based on schema types — complex validation rules may cause 400 errors

---

## How It Works

1. **ResolveEndpoints.ps1** reads your `swagger.json` and builds a list of endpoints with auto-generated request bodies based on the schema
2. **TestFramework.ps1** handles all HTTP calls, timing, and result tracking
3. **TestRunner.ps1** orchestrates everything — filters, orders, and runs the tests, then prints a summary

---

## Project Structure

```
.
├── ResolveEndpoints.ps1   # Parses OpenAPI spec, builds endpoint + request body list
├── TestFramework.ps1      # HTTP request functions, result tracking, summary
├── TestRunner.ps1         # Orchestration, filtering, ordering, output
└── swagger.json           # Your OpenAPI spec
```

---

## Requirements

- PowerShell 7.0+
- A running API with an accessible Swagger/OpenAPI spec (`swagger.json`)

---

## Usage

### Run locally

```powershell
.\TestRunner.ps1 `
  -openApiSpecPath ".\swagger.json" `
  -baseUrl "http://localhost:your-port-number" `
  -accessToken "your_token_here" `
  -methods "get,post,put,delete" `
  -showDetailedErrors $true
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `openApiSpecPath` | `.\swagger.json` | Path to your OpenAPI spec |
| `baseUrl` | `http://localhost:8080` | Base URL of the API |
| `accessToken` | `your_token_here` | Bearer token for authentication |
| `failOnTestFailures` | `true` | Exit with code 1 if any tests fail |
| `skipPaths` | `` | Comma-separated path segments to skip (e.g. `auth,admin`) |
| `methods` | `get,post,put,delete` | Comma-separated HTTP methods to run |
| `showDetailedErrors` | `false` | Print status code, title, and field errors for failed requests |

---

## Features

### Auto-generated Request Bodies

Request bodies are automatically generated from your OpenAPI component schemas. Supported types:

| OpenAPI Type | Generated Value |
|---|---|
| `integer` | `1` |
| `number` | `0.0` |
| `boolean` | `false` |
| `string` | `"test"` |
| `string (date-time)` | Current timestamp |
| `string (date)` | Current date |
| `array` | `[]` |
| `object` | `{}` |
| Enum `$ref` | First enum value |
| Nested object `$ref` | Recursively resolved |

### Path Parameter Resolution

Path parameters like `/api/Team/{id}` are automatically replaced with a placeholder value of `1`.

### Detailed Error Output

With `-showDetailedErrors $true`, failed requests show structured error information:

```
  -> POST /api/Schedule/create  FAILED
    Status  : 400
    Title   : One or more validation errors occurred.
    Errors  :
      1. scheduleDate: The JSON value could not be converted to System.Nullable`1[System.DateTime]
      2. dto: The dto field is required.
```

### Test Summary

Every run prints a summary:

```
================================
  Total  : 24
  Passed : 21
  Failed : 3
  Total  : 4823 ms
  Avg    : 200 ms
================================
```

---

## CI/CD Integration

### GitHub Actions

see "GitHubActions.yaml" for example

### Azure DevOps

see "AzureDevops.yaml" for example

**Variables to configure:**
- `API_BASE_URL` — pipeline variable
- `API_ACCESS_TOKEN` — secret variable

---

## Upcoming Features

- **Manual priority overrides** — explicitly set execution order for specific endpoints via a config hashtable in `TestRunner.ps1`
- **Response chaining** — capture IDs from POST responses and inject them into subsequent GET/PUT/DELETE path parameters instead of using placeholder values
- **More auth types** - Adding more options beyond Bearer token
- **Configurable default values** - Letting the user enter default values to match when validation is in the way :)

---

