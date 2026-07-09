# SmokeAlarm

## PowerShell API Test Framework

### Current version: 0.7.0

#### Last updated: 2026-07-09

A lightweight, OpenAPI-driven test framework for automatically generating and running simple API smoke tests from a Swagger/OpenAPI spec.

Also includes option to manually enter test requests in json http request format.

### Advantages

- Simple to use, just put it in your pipeline, point it towards your api and spec and run it.
- Filterable (http methods, paths) - Dont test endpoints you dont want to test
- Configurable (detailed errors, save reports, fail pipeline on error)
- Automatically chains requests — captures IDs from responses and reuses them in subsequent calls, otherwise falls back to defaults
- Generates easy-to-read HTML Reports that facilitates simpler bug hunting

### Limitations

- Auth is Bearer token only
- Request bodies are best-effort based on schema types - complex validation rules may cause 400 errors
- Sensitive to ambiguity - works best with a clear readable endpoint structure => api/controller/keyword/{specifiedId} (api/bookings/update/{bookingId})

---

## How It Works

1. **ResolveEndpoints.ps1** reads your `swagger.json` and builds a list of endpoints with auto-generated request bodies based on the schema
2. **TestFramework.ps1** handles all HTTP calls, timing, and result tracking
3. **TestRunner.ps1** orchestrates everything — filters, orders, and runs the tests, then prints a summary
4. **EndpointPriority.ps1** controls execution order, auto-prioritized by path pattern with optional manual overrides
5. **AuthFlow.ps1** handles optional login using pipeline secrets
6. **EndpointWarnings.ps1** looks through endpoint calls for possible issues with test framework and collects them for presentation
7. **Run-SmokeTests.ps1** Runs the tests locally in an easier to set-up format.

---

## Project Structure

```
.
├── ResolveEndpoints.ps1   # Parses OpenAPI spec, builds endpoint + request body list
├── TestFramework.ps1      # HTTP request functions, result tracking, summary
├── TestRunner.ps1         # Orchestration, filtering, ordering, output
├── EndpointPriority.ps1   # Execution order config
├── AuthFlow.ps1           # Optional (Auth) login
├── EndpointWarnings.ps1   # Test execution warnings
├── reportStyle.css        # Style for HTML report
└── swagger.json           # Your OpenAPI spec
```

---

## Requirements

- PowerShell 7.0+
- A running API with an accessible Swagger/OpenAPI spec (`swagger.json`)

---

## Usage

### Run locally

#### Powershell

```
.\TestRunner.ps1 `
  -openApiSpecPath ".\swagger.json" `
  -baseUrl "http://localhost:your-port-number" `
  -accessToken "your_token_here" `
  -username "your_api_username_here" `
  -password "your_api_password_here" `
  -methods "get,post,put,delete" `
  -showDetailedErrors $true
  -saveReports $true
  -reportLocation ".\reports\"
  -maxReports 10
  -maxAgeDays 10
```

#### Run-SmokeTests (recommended for local dev)

Drop `Run-SmokeTests.ps1` into the solution root alongside the other scripts and run it:

```
.\Run-SmokeTests.ps1
```

**First run:** auto-detects the OpenAPI spec and base URL from `launchSettings.json`, prompts for any missing config, and saves everything to `smoketest.config.json`.

**Subsequent runs:** reads the config and runs immediately — no arguments needed.

##### Authentication

Credentials are read from environment variables at runtime:

```
$env:SMOKETEST_USERNAME = "admin"
$env:SMOKETEST_PASSWORD = "yourpassword"
```

For a long-lasting token (e.g. in local dev), set `accessToken` directly in `smoketest.config.json` and credentials will be skipped.

##### Configuration

Edit `smoketest.config.json` to customise behaviour. The file is created with sensible defaults on first run.

```json
{
  "baseUrl": "http://localhost:5193",
  "openApiSpecPath": ".\\swagger.json",
  "accessToken": "",
  "authEndpoint": "/api/Auth/login",
  "usernameEnvVar": "SMOKETEST_USERNAME",
  "passwordEnvVar": "SMOKETEST_PASSWORD",
  "reportLocation": ".\\reports\\",
  "failOnTestFailures": true,
  "skipPaths": ["auth"],
  "methods": ["get", "post", "put", "delete"],
  "postOrder": [],
  "showDetailedErrors": true,
  "saveReports": true,
  "maxReports": 10,
  "maxAgeDays": 10
}
```

##### Controlling POST execution order

If your API has resource dependencies (e.g. a Schedule requires a Stage, which requires a Competition), you can define the exact order plain POST endpoints run in via `postOrder` in `smoketest.config.json`:

```json
"postOrder": [
  "/api/Competitions",
  "/api/Seasons",
  "/api/Stages",
  "/api/Schedules",
  "/api/Participants"
]
```

Endpoints not listed will be appended after the configured ones in auto-priority order. This overrides the automatic dependency detection for plain POSTs.

##### Parameters

| Parameter            | Default                   | Description                                                                  |
| -------------------- | ------------------------- | ---------------------------------------------------------------------------- |
| `openApiSpecPath`    | `.\swagger.json`          | Path to your OpenAPI spec                                                    |
| `baseUrl`            | `http://localhost:8080`   | Base URL of the API                                                          |
| `accessToken`        | `null`                    | Bearer token for authentication. Use either this or `username`/`password`    |
| `username`           | `null`                    | Username for authentication. Use either this or `accessToken`                |
| `password`           | `null`                    | Password for authentication. Use either this or `accessToken`                |
| `failOnTestFailures` | `true`                    | Exit with code 1 if any tests fail                                           |
| `skipPaths`          | ``                        | Comma-separated path segments to skip (e.g. `auth,admin`)                   |
| `methods`            | `get,post,put,delete`     | Comma-separated HTTP methods to run                                          |
| `showDetailedErrors` | `true`                    | Print status code, title, and field errors for failed requests               |
| `saveReports`        | `true`                    | Whether to save HTML reports                                                 |
| `reportLocation`     | `.\reports\`              | Folder path where HTML reports are saved                                     |
| `maxReports`         | `10`                      | Maximum number of reports to keep. Oldest are removed first. `0` = unlimited |
| `maxAgeDays`         | `10`                      | Maximum age of reports in days. `0` = unlimited                              |
| `overridesPath`      | `.\requestOverrides.json` | Path to load manual overrides from                                           |
| `postOrder`          | `@()`                     | Explicit execution order for plain POST endpoints                            |

---

## Features

### Auto-generated Request Bodies

Request bodies are automatically generated from your OpenAPI component schemas. Supported types:

| OpenAPI Type         | Generated Value      |
| -------------------- | -------------------- |
| `integer`            | `1`                  |
| `number`             | `0.0`                |
| `boolean`            | `false`              |
| `string`             | `"test"`             |
| `string (date-time)` | Current timestamp    |
| `string (date)`      | Current date         |
| `string (enum)`      | First enum value     |
| `array`              | `[]`                 |
| `object`             | `{}`                 |
| Enum `$ref`          | First enum value     |
| Nested object `$ref` | Recursively resolved |

Nullable enum query parameters (e.g. filter fields) are omitted entirely rather than sending an invalid placeholder value.

Self-referential integer fields (e.g. `nextStageId` on a Stage) are sent as `null` on creation to avoid circular dependency errors.

### Response Chaining

IDs are automatically captured from POST responses and injected into subsequent requests at runtime. PUT requests use captured responses from GET requests.

```
-> POST /api/Holiday/create  PASSED
   Captured: Holiday = 1017
-> POST /api/booking/create  PASSED
   Captured: Booking = 1034
-> GET /api/Booking/1034
-> PUT /api/Booking/change-dates/1034  PASSED
-> GET /api/Holiday/1017/get-bookings  PASSED
```

Works for:

- **Path parameters** — `/api/Team/{teamId}` → `/api/Team/42`
- **Query parameters** — `?scheduleId={id}` → `?scheduleId=7`
- **Request body fields** — including compound camelCase names like `competitionRoundStageId` → resolved to the captured `stage` ID
- **Request body arrays** — `playerIds: [0]` → `playerIds: [42]`
- **Raw array requests**

### Smart Test Ordering

Endpoints are automatically ordered based on path patterns and HTTP method so that create operations run before reads, updates, and deletes.

| Pattern              | Priority |
| -------------------- | -------- |
| `*/register*`        | 1st      |
| `*/login*`           | 2nd      |
| `*/create*`          | 3rd      |
| `*/add*`             | 4th      |
| Plain resource POSTs | 5th      |
| `*/update*`          | 6th      |
| `*/remove*`          | 7th      |
| `*/delete*`          | 8th      |
| Action POSTs (`/regenerate`, `/advance` etc.) | after GETs/PUTs |
| everything else      | last     |

Within each group, methods run in order: `POST → GET → PUT → DELETE`.

Plain POSTs (no path parameters, no action segment) always run before action endpoints on the same resource. Use `postOrder` in config to explicitly control inter-resource ordering when the automatic detection isn't sufficient.

### Manual Priority Overrides

For endpoints with explicit dependencies, set exact priorities in `EndpointPriority.ps1`:

```
$script:priorityOverrides = @{
    '/api/Auth/register' = 1
    '/api/Auth/login'    = 2
    'etc...'             = 3
}
```

Manual overrides always take precedence over auto-priority. Everything without an override falls through to pattern-based ordering.

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

Known status codes with empty bodies (401, 403, 404 etc.) show a plain-language reason instead.

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
WARNINGS (1):
Ambiguous Path Parameter (1):
Ambiguous path parameter '{id}' in GET /api/entity/otherentity/{id} - rename to specific entity name to improve test accuracy
================================
```

### HTML Reports

By default, SmokeAlarm saves an HTML report for each test run to `.\reports\`. Reports are named by timestamp:

```
reports/SmokeAlarm_Report_2026-05-30_16-48-07.html
```

Reports include a summary card with pass/fail counts and total duration, and a per-request table with method, path, status code, result, and error details for failed requests. It also includes a list of found issues that could disturb test execution.

Use `-saveReports $false` to disable report saving entirely.

#### Limiting saved reports

Use `-maxReports` and `-maxAgeDays` to automatically clean up old reports after each run:

```
.\SmokeAlarm.ps1 -maxReports 10 -maxAgeDays 10
```

- `-maxReports 10` — keeps the 10 most recent reports, deletes the rest
- `-maxAgeDays 10` — deletes any report older than 10 days
- Both can be used together; age cleanup runs first
- Set either to `0` for unlimited

#### Custom report location

Use `-reportLocation` to save reports to a different folder:

```
.\SmokeAlarm.ps1 -reportLocation "C:\test-reports\"
```

The folder will be created automatically if it does not exist.

### Request Overrides

SmokeAlarm can generate a `requestOverrides.json` file pre-populated with all endpoints and their auto-generated request bodies. You can then manually edit specific entries and enable them to take precedence over the auto-generated requests.

#### Generating the overrides file

```
.\GenerateOverrides.ps1 -openApiSpecPath ".\swagger.json" -outputPath ".\requestOverrides.json"
```

This generates a file with one entry per endpoint, all disabled by default:

```json
[
  {
    "method": "POST",
    "path": "/api/Competition/create",
    "enabled": false,
    "body": {
      "name": "test",
      "description": "test",
      "isActive": false,
      "competitionTypeId": 2,
      "competitionPresetId": 2
    }
  }
]
```

#### Enabling an override

Set `enabled` to `true` and edit the values as needed:

```json
{
  "method": "POST",
  "path": "/api/Booking/create",
  "enabled": true,
  "body": {
    "name": "My Booking",
    "description": "A small room",
    "isActive": true,
    "bookingTypeId": 1,
    "customerTypeId": 3
  }
}
```

When an override is enabled, it replaces the auto-generated request entirely. Enabled overrides are marked as **MANUAL** in both the console output and the HTML report.

Re-generating the overrides file is safe — existing entries and manual edits are preserved. Only new endpoints are added.

#### Parameters

| Parameter         | Default                   | Description                                           |
| ----------------- | ------------------------- | ----------------------------------------------------- |
| `openApiSpecPath` | `.\swagger.json`          | Path to your OpenAPI spec                             |
| `outputPath`      | `.\requestOverrides.json` | Where to save the generated overrides file            |
| `overridesPath`   | `.\requestOverrides.json` | Path passed to the test runner to load overrides from |

---

## CI/CD Integration

### GitHub Actions

See `GitHubActions.yaml` for example.

### Azure DevOps

See `AzureDevops.yaml` for example.

**Secret variables** (configure in pipeline settings, not in yaml):

- `API_BASE_URL` — base URL of the API
- `API_ACCESS_TOKEN` — bearer token, use either this or `API_USERNAME`/`API_PASSWORD`
- `API_USERNAME` — username for authentication
- `API_PASSWORD` — password for authentication

**Pipeline variables** (safe to define in yaml):

- `FAIL_ON_TEST_FAILURES` — exit with code 1 if any tests fail. Default: `true`
- `SKIP_PATHS` — comma-separated path segments to skip. Default: `'auth,admin'`
- `METHODS` — quote-wrapped comma-separated HTTP methods to run. Default: `'get','post','put','delete'`
- `SHOW_DETAILED_ERRORS` — print structured error details for failed requests. Default: `false`
- `SAVE_REPORTS` — whether to save HTML reports. Default: `true`
- `MAX_REPORTS` — maximum number of reports to keep. Default: `10`
- `MAX_AGE_DAYS` — maximum age of reports in days. Default: `10`

### Docker

Run smoke tests as a post-deploy step before routing traffic:

```yaml
services:
  api:
    build: .
    ports:
      - "5193:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
      interval: 5s
      retries: 5

  smoketests:
    image: mcr.microsoft.com/powershell:latest
    volumes:
      - ./SmokeTests:/tests
    environment:
      - SMOKETEST_USERNAME=admin
      - SMOKETEST_PASSWORD=yourpassword
    command: pwsh /tests/testrunner.ps1 -baseUrl http://api:8080 -openApiSpecPath /tests/swagger.json
    depends_on:
      api:
        condition: service_healthy
```

---

## Upcoming Features

- **More auth types** — adding more options beyond Bearer token
- **Configurable default values** — letting the user enter default values to match when validation is in the way
- **Validation hunting** — finding active validation in API and adjusting request bodies automatically

---

## Changelog

### 0.7.0

- **Feature: `postOrder` config** — explicit execution order for plain POST endpoints via `smoketest.config.json`, solving inter-resource dependency issues the automatic detection can't infer from the spec
- **Fix: Compound camelCase ID resolution** — fields like `competitionRoundStageId` now correctly resolve to the captured `stage` ID by extracting the last meaningful word segment
- **Fix: Self-referential nullable fields** — integer fields referencing the same resource being created (e.g. `nextStageId` on a Stage) are now sent as `null` instead of a non-existent ID
- **Fix: Nullable enum query parameters** — optional enum filter params are omitted from query strings instead of sending `"test"` as a placeholder value
- **Fix: Plain POSTs always run before action POSTs** — `/api/Schedules` now always runs before `/api/Schedules/{id}/regenerate`
- **Fix: PowerShell 5 compatibility** — replaced `??` null coalescing operators for environments without PS7
- **Fix: Encoding** — replaced Unicode box-drawing and emoji characters with plain ASCII for cross-platform compatibility

### 0.6.0

- **Feature: Added Run-SmokeTests.ps1** — simplifies running tests locally in development
- **Fix: Further enum improvements**

### 0.5.1

- **Fix: Better detection and usage of Enum values**

### 0.5.0

- **Added manual request overrides**

### 0.4.2

- **Added GET missing POST warning** — added a warning if a GET endpoint doesn't have a corresponding POST / create endpoint. Ignores read-only controllers.
- **Fix: Removed debug lines**
- **Chore: Clarified a few lines in readme**

### 0.4.1

- **Improved auto dependency ordering** — adds GETs as dependencies for PUTs if applicable.
- **Support for more edge cases** — raw array request bodies, saving multiple IDs from responses, nested DTOs in requests

### 0.4.0

- **Using GET response in PUT requests** — to more accurately simulate real API behavior
- **Test Execution Warnings** — console and HTML summary now includes warnings of endpoint issues
- **Improved auto dependency ordering** — endpoint calls on same entities now sorted by additional keywords

### 0.3.2

- **Improved auto dependency ordering** — deletes are now run in reverse order of creates
- **Improved response chaining** — finds entity IDs in nested response DTOs

### 0.3.1

- **Auto dependency ordering** — endpoints are now automatically sorted so POST producers run before consumers. Manual overrides still take precedence.

### 0.3.0

- **HTML reports** — timestamped HTML report with summary card and per-request results table
- **Report retention** — automatic cleanup by count or age
- **Username/password authentication** — alternative to `-accessToken`
- **Fix: Array request body support**
- **Fix: Response chaining for arrays**

### 0.2.0

- **Response chaining** — IDs captured from POST responses injected into subsequent requests
- **Manual priority overrides**
- **Query parameter resolution**
- **Enum support**
- **DateTime support**
- **Improved error output**

### 0.1.0

- Initial release
- Auto-generated request bodies from OpenAPI schemas
- Path parameter placeholder resolution
- Smart test ordering by path pattern and HTTP method
- Detailed error output with `-showDetailedErrors`
- Test summary with pass/fail counts and timing
- GitHub Actions and Azure DevOps pipeline support
