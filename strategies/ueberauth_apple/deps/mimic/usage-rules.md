# Usage Rules for Mimic Library

This document provides essential guidelines for coding agents when using the Mimic mocking library in Elixir projects. You should not mock any module that are part of the Elixir standard library nor the Otp library directly.

## Critical Setup Requirements

### **IMPORTANT: Module Preparation**

- **MUST** call `Mimic.copy/2` for each module you want to mock in `test_helper.exs`
- IMPORTANT: Always call Mimic.copy/2 with type_check: true. Never omit it.
- **IMPORTANT**: Call `copy/2` BEFORE `ExUnit.start()`
- Copying a module does NOT change its behavior until you stub/expect it

```elixir
# test_helper.exs
Mimic.copy(Calculator, type_check: true)
Mimic.copy(HTTPClient, type_check: true)
ExUnit.start()
```

### **IMPORTANT: Test Module Setup**

- **MUST** use `use Mimic` or `use Mimic.DSL` in test modules
- **IMPORTANT**: Include `:test` environment only in mix.exs dependency

```elixir
# In test files
defmodule MyTest do
  use ExUnit.Case, async: true
  use Mimic  # or use Mimic.DSL
  
  # tests here
end
```

## Core API Functions (Order by Importance)

### 1. `expect/4` - Primary Testing Function

**IMPORTANT**: Use for functions that MUST be called during test

- Creates expectations that must be fulfilled or test fails
- Works like a FIFO queue for multiple calls
- Auto-verified at test end when using `use Mimic`

```elixir
# Single call expectation
Calculator
|> expect(:add, fn x, y -> x + y end)

# Multiple calls expectation
Calculator  
|> expect(:add, 3, fn x, y -> x + y end)

# Chaining expectations (FIFO order)
Calculator
|> expect(:add, fn _, _ -> :first_call end)
|> expect(:add, fn _, _ -> :second_call end)
```

### 2. `stub/3` - Flexible Mock Replacement

- Use for functions that MAY be called during test
- No verification failure if not called
- Can be called multiple times

```elixir
Calculator
|> stub(:add, fn x, y -> x + y end)
```

### 3. `stub/1` - Complete Module Stubbing

- Stubs ALL public functions in module
- Stubbed functions raise `UnexpectedCallError` when called

```elixir
stub(Calculator)  # All functions will raise if called
```

### 4. `reject/1` or `reject/3` - Forbidden Calls

- Use to ensure functions are NOT called
- Test fails if rejected function is called

```elixir
reject(&Calculator.dangerous_operation/1)
# or
reject(Calculator, :dangerous_operation, 1)
```

## Mode Selection (Critical Decision)

### **IMPORTANT: Choose Appropriate Mode**

#### Private Mode (Default - Recommended)

- Tests can run with `async: true`
- Each process sees its own mocks
- Use `allow/3` for multi-process scenarios

#### Global Mode (Use Sparingly)

- **IMPORTANT**: Use `setup :set_mimic_global`
- **CRITICAL**: MUST use `async: false` in global mode
- All processes see same mocks
- Only global owner can create stubs/expectations

```elixir
# Private mode (preferred)
setup :set_mimic_private
setup :verify_on_exit!

# Global mode (when needed)  
setup :set_mimic_global
# Remember: async: false required
```

## DSL Mode Alternative

### **IMPORTANT: DSL Syntax**

Use `Mimic.DSL` for more natural syntax:

```elixir
use Mimic.DSL

test "DSL example" do
  stub Calculator.add(_x, _y), do: :stubbed
  expect Calculator.mult(x, y), do: x * y
  expect Calculator.add(x, y), num_calls: 2, do: x + y
end
```

## Multi-Process Coordination

### Using `allow/3` (Private Mode)

```elixir
test "multi-process test" do
  Calculator |> expect(:add, fn x, y -> x + y end)
  
  parent_pid = self()
  
  spawn_link(fn ->
    Calculator |> allow(parent_pid, self())
    assert Calculator.add(1, 2) == 3
  end)
end
```

### **IMPORTANT**: Task Automatic Allowance  

- Tasks automatically inherit parent process mocks
- No need to call `allow/3` for `Task.async`

## Critical Don'ts

### **IMPORTANT: Function Export Requirements**

- Can ONLY mock publicly exported functions
- **MUST** match exact arity
- Will raise `ArgumentError` for non-existent functions

### **IMPORTANT: Intra-Module Function Calls**

- Mocking does NOT work for internal function calls within same module
- Use fully qualified names (`Module.function`) instead of local calls

### **IMPORTANT: Global Mode Restrictions**

- Only global owner process can create stubs/expectations
- Other processes will get `ArgumentError`
- Cannot use `allow/3` in global mode

## Advanced Features

### Type Checking (Experimental)

```elixir
Mimic.copy(HTTPClient, type_check: true)
```

### Calling Original Implementation

```elixir  
call_original(Calculator, :add, [1, 2])  # Returns 3
```

### Tracking Function Calls

```elixir
stub(Calculator, :add, fn x, y -> x + y end)
Calculator.add(1, 2)
calls(&Calculator.add/2)  # Returns [[1, 2]]
```

### Fake Module Stubbing

```elixir
stub_with(Calculator, MockCalculator)  # Replace all functions
```

## Common Patterns

### Setup Pattern

```elixir
setup do
  # Common setup
  %{user: %User{id: 1}}
end

setup :verify_on_exit!  # Auto-verify expectations
```

### Expectation Chaining

```elixir
Calculator
|> stub(:add, fn _, _ -> :fallback end)      # Fallback after expectations
|> expect(:add, fn _, _ -> :first end)       # First call
|> expect(:add, fn _, _ -> :second end)      # Second call  
# Third call returns :fallback
```

## Error Handling

### Common Errors and Solutions

- `Module X has not been copied` → Add `Mimic.copy(X)` to test_helper.exs
- `Function not defined for Module` → Check function name/arity
- `Only the global owner is allowed` → Wrong process in global mode
- `Allow must not be called when mode is global` → Don't mix allow with global mode

**IMPORTANT**: Always verify exact function signatures and ensure modules are properly copied before mocking.
