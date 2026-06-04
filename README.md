# SmokeAlarm 
## PowerShell API Test Framework

### Current version: 0.4.1
#### Last updated: 2026-06-03

A lightweight, OpenAPI-driven test framework for automatically generating and running simple API smoke tests from a Swagger/OpenAPI spec. 

### Advantages
- Simple to use, just put it in your pipeline, point it towards your api and spec and run it.
- Filterable (http methods, paths) and configurable (detailed errors, fail pipeline on error)
- Automatically chains requests — captures IDs from responses and reuses them in subsequent calls
- Generates easy-to-read HTML Reports that facilitates simpler bug hunting

### Limitations

- Auth is Bearer token only
- Request bodies are best-effort based on schema types — complex validation rules may cause 400 errors

---

## How It Works

1. **ResolveEndpoints.ps1** reads your `swagger.json` and builds a list of endpoints with auto-generated request bodies based on the schema
2. **TestFramework.ps1** handles all HTTP calls, timing, and result tracking
3. **TestRunner.ps1** orchestrates everything —> filters, orders, and runs the tests, then prints a summary
4. **EndpointPriority.ps1** controls execution order, auto-prioritized by path pattern with optional manual overrides
5. **AuthFlow.ps1** handles optional login using pipeline secrets
6. **EndpointWarnings.ps1** looks trough endpoint calls for possible issues with test framework and collects them for presentation
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

```powershell
.\TestRunner.ps1 `
  -openApiSpecPath ".\swagger.json" `
  -baseUrl "http://localhost:your-port-number" `
  -accessToken "your_token_here" `
  -username "your_api_username_here" `
  -password "your_api_password_here" `
  -methods "get,post,put,delete" `
  -showDetailedErrors $true
  -saveReports $true
  -reportLocation = ".\reports\"
  -maxReports 10
  -maxAgeDays 10,
  -
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `openApiSpecPath` | `.\swagger.json` | Path to your OpenAPI spec |
| `baseUrl` | `http://localhost:8080` | Base URL of the API |
| `accessToken` | `null` | Bearer token for authentication. Use either this or `username`/`password` |
| `username` | `null` | Username for authentication. Use either this or `accessToken` |
| `password` | `null` | Password for authentication. Use either this or `accessToken` |
| `failOnTestFailures` | `true` | Exit with code 1 if any tests fail |
| `skipPaths` | `` | Comma-separated path segments to skip (e.g. `auth,admin`) |
| `methods` | `get,post,put,delete` | Comma-separated HTTP methods to run |
| `showDetailedErrors` | `true` | Print status code, title, and field errors for failed requests |
| `saveReports` | `true` | Whether to save HTML reports |
| `reportLocation` | `.\reports\` | Folder path where HTML reports are saved |
| `maxReports` | `10` | Maximum number of reports to keep. Oldest are removed first. `0` = unlimited |
| `maxAgeDays` | `10` | Maximum age of reports in days. `0` = unlimited |

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

### Response Chaining

IDs are automatically captured from POST responses and injected into subsequent requests at runtime.
PUT requests use captured responses from GET requests.

```
  -> POST /api/Holiday/create  PASSED
     Captured: Holiday = 1017
  -> POST /api/booking/create  PASSED
     Captured: Booking = 1034
  -> GET /api/Booking/1034
  -> PUT /api/Booking/change-dates/1034  PASSED
  -> GET /api/Holiday/1017  PASSED
```

Works for:
- **Path parameters** — `/api/Team/{teamId}` → `/api/Team/42`
- **Query parameters** — `?scheduleId={id}` → `?scheduleId=7`
- **Request body arrays** — `playerIds: [0]` → `playerIds: [42]`

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

Tests are further ordered by comparing response values from POST requests to upcoming api paths/request values.

Tests are also ordered by keywords, for example running tests on api paths containing 'remove' after paths containing 'add'.

DELETE requests are run in reverse order from matching GET requests to avoid cascading delete errors.

### Manual Priority Overrides

For endpoints with explicit dependencies, set exact priorities in `EndpointPriority.ps1`:

```powershell
$script:priorityOverrides = @{
    '/api/Auth/register'           = 1
    '/api/Auth/login'              = 2
    'etc...'
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
================================
WARNINGS (1):
Ambigous Path Parameter (1):
Ambigous path parameter '{id}' in GET /api/entity/otherentity/{id} - rename to specific entity name to improve test accuracy
================================
```
### HTML Reports

By default, SmokeAlarm saves an HTML report for each test run to `.\reports\`. Reports are named by timestamp:

```
reports/SmokeAlarm_Report_2026-05-30_16-48-07.html
```

Reports include a summary card with pass/fail counts and total duration, and a per-request table with method, path, status code, result, and error details for failed requests.
It also includes a list of found issues that could disturb test execution.

Use `-saveReports $false` to disable report saving entirely.

#### Limiting saved reports

Use `-maxReports` and `-maxAgeDays` to automatically clean up old reports after each run:

```powershell
.\SmokeAlarm.ps1 -maxReports 10 -maxAgeDays 10
```

- `-maxReports 10` — keeps the 10 most recent reports, deletes the rest
- `-maxAgeDays 10` — deletes any report older than 10 days
- Both can be used together; age cleanup runs first
- Set either to `0` for unlimited

#### Custom report location

Use `-reportLocation` to save reports to a different folder:

```powershell
.\SmokeAlarm.ps1 -reportLocation "C:\test-reports\"
```

The folder will be created automatically if it does not exist.
---

## CI/CD Integration

### GitHub Actions

see `GitHubActions.yaml` for example

### Azure DevOps

see `AzureDevops.yaml` for example

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

---

## Upcoming Features

- **More auth types** — adding more options beyond Bearer token
- **Configurable default values** — letting the user enter default values to match when validation is in the way
- **Validation hunting** - finding active validation in API and adjusting request bodies automatically

---

## Changelog

### 0.4.1
- **Improved auto dependency ordering** - Adds GETs as dependencies for PUTs if applicable.
- **Support for more edge cases** -
    - Sending raw arrays as request bodies
    - Saving multiple ids from responses
    - Sending nested DTOs in requests
  
### 0.4.0
- **Using GET response in PUT requests** - To more accurately simulate real API behavior
- **Test Execution Warnings** - Both console and html test summary now includes warnings of endpoint issues that could decrease API readability and disturb test execution.
- **Improved auto dependency ordering** - endpoint calls on same entities now sorted by additional keywords (add before remove etc.).
  
### 0.3.2
- **Improved auto dependency ordering** - Added filtering of "other" POST endpoint to depend on create being called first. Deletes are now run in reverse order of creates.
- **Improved response chaining** - Now finds entity ids in nested response DTOs and uses them in calls where applicable. Also smoothed out some edge cases (matching words ending with "s" etc.) 
  
### 0.3.1
- **Auto dependency ordering** — endpoints are now automatically sorted so POST producers run before the endpoints that consume their produced IDs. Manual overrides in `EndpointPriority.ps1` still take precedence

### 0.3.0
- **HTML reports** — test runs can now generate a timestamped HTML report with a summary card and per-request results table (optional)
- **Report retention** — reports are automatically cleaned up by count (`-maxReports`) or age (`-maxAgeDays`) after each run
- **Username/password authentication** — `-username` and `-password` can now be used as an alternative to `-accessToken`
- **Fix: Array request body support** — request body properties typed as arrays are now correctly serialized as JSON arrays instead of scalars
- **Fix: Response chaining for arrays** — FIX: captured IDs are injected into array-typed request body fields, collecting all matching IDs from the test run

### 0.2.0
- **Response chaining** — IDs captured from POST responses are now automatically injected into path parameters, query parameters, and request body arrays of subsequent requests
- **Manual priority overrides** — explicit execution order can now be set per endpoint in `EndpointPriority.ps1`
- **Query parameter resolution** — query parameters defined in the OpenAPI spec are now auto-generated and appended to GET requests
- **Enum support** — request body properties referencing enum schemas now use the first valid enum value instead of null
- **DateTime support** — string properties with `date-time` or `date` format now generate valid timestamp values
- **Improved error output** — known status codes with empty bodies (401, 403, 404 etc.) now show a plain-language reason; structured validation errors are displayed per field

### 0.1.0
- Initial release
- Auto-generated request bodies from OpenAPI schemas
- Path parameter placeholder resolution
- Smart test ordering by path pattern and HTTP method
- Detailed error output with `-showDetailedErrors`
- Test summary with pass/fail counts and timing
- GitHub Actions and Azure DevOps pipeline support
