# Anti-Pattern Reference

Detailed examples of each anti-pattern with a problem case and a fix. Examples are language-agnostic where possible; Python used for concreteness.

---

## Silent Failure: Empty except block

**Problem**
```python
def load_config(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        pass  # caller receives None with no indication of why
```

**Fix**
```python
def load_config(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        raise ConfigError(f"Config file not found: {path}")
    except json.JSONDecodeError as e:
        raise ConfigError(f"Invalid JSON in config: {e}")
```

---

## Silent Failure: Hardcoded default masking computation

**Problem**
```python
def calculate_checksum(data):
    # TODO: implement properly
    return "abc123"  # always returns the same value
```

**Fix**: Either implement it or raise `NotImplementedError`. Never return a value that looks real but isn't.

---

## Silent Failure: Broad try/catch over function body

**Problem**
```python
def process_record(record):
    try:
        validate(record)
        transformed = transform(record)
        save(transformed)
        return True
    except Exception:
        return False  # caller can't distinguish validation failure from DB failure
```

**Fix**: Catch specific exceptions at specific sites, or let them propagate with context.

```python
def process_record(record):
    validate(record)  # raises ValidationError — let it propagate
    transformed = transform(record)
    try:
        save(transformed)
    except StorageError as e:
        raise ProcessingError(f"Failed to save record {record.id}") from e
    return True
```

---

## Completeness: Stub disguised as implementation

**Problem**
```python
def retry_with_backoff(fn, max_attempts=5):
    # TODO: add exponential backoff
    return fn()  # ignores max_attempts entirely
```

The function signature implies behavior that isn't implemented. Callers configure `max_attempts` and receive no benefit.

**Fix**: Implement it or remove the parameter. Do not accept configuration you don't use.

---

## Hardcoded values: Magic numbers

**Problem**
```python
def is_context_burned(call_count):
    return call_count > 50  # why 50?
```

**Fix**
```python
CONTEXT_BURN_THRESHOLD = 50  # calls without edit/write before flagging

def is_context_burned(call_count):
    return call_count > CONTEXT_BURN_THRESHOLD
```

---

## Hardcoded values: Environment-specific path

**Problem**
```python
LOG_DIR = "/home/brentw/.claude/logs"
```

**Fix**
```python
LOG_DIR = Path(os.environ.get("CLAUDE_LOG_DIR", Path.home() / ".claude" / "logs"))
```

---

## Over-engineering: Class for a one-time operation

**Problem**
```python
class ConfigLoader:
    def __init__(self, path):
        self.path = path

    def load(self):
        with open(self.path) as f:
            return json.load(f)

# called once, at startup
config = ConfigLoader("config.json").load()
```

**Fix**
```python
def load_config(path):
    with open(path) as f:
        return json.load(f)

config = load_config("config.json")
```

---

## Over-engineering: Premature abstraction

**Problem**: A generic `BaseProcessor` with `preprocess`, `process`, `postprocess` hooks — with exactly one subclass that uses all three.

**Fix**: Write the one implementation directly. Extract a base class if and when a second implementation is actually needed.

---

## Copy-paste code: Duplicated logic

**Problem**
```python
def validate_user_input(data):
    if not data.get("name"):
        raise ValueError("name is required")
    if len(data["name"]) > 100:
        raise ValueError("name too long")

def validate_config_input(data):
    if not data.get("name"):
        raise ValueError("name is required")
    if len(data["name"]) > 100:
        raise ValueError("name too long")
```

**Fix**
```python
def validate_name_field(data, max_length=100):
    if not data.get("name"):
        raise ValueError("name is required")
    if len(data["name"]) > max_length:
        raise ValueError(f"name exceeds {max_length} characters")

def validate_user_input(data):
    validate_name_field(data)

def validate_config_input(data):
    validate_name_field(data)
```

---

## Inconsistent error handling

**Problem**
```python
def read_file(path):
    with open(path) as f:  # raises FileNotFoundError — unhandled
        return f.read()

def write_file(path, content):
    try:
        with open(path, "w") as f:
            f.write(content)
    except IOError as e:
        logger.error(f"Write failed: {e}")
        return False
    return True
```

Read and write have completely different error contracts. Callers must handle them differently.

**Fix**: Establish a consistent error contract for the module. Either both propagate, or both return error values, or both log-and-return. Pick one and apply it uniformly.

---

## Missing cleanup: Resource leak

**Problem**
```python
def process_large_file(path):
    f = open(path)
    data = f.read()
    result = expensive_transform(data)  # if this raises, f is never closed
    f.close()
    return result
```

**Fix**
```python
def process_large_file(path):
    with open(path) as f:
        data = f.read()
    return expensive_transform(data)
```

Use context managers for all resources. If a context manager isn't available, use try/finally.
