# telemetry-log-correlation Specification

## Purpose

Make structured journal trace context searchable without inventing request context, dropping malformed logs or allowing application payloads to shadow journal metadata.

## Requirements

### Requirement: Structured trace context is normalized

Journal shipping SHALL normalize supported trace_id and span_id keys from source fields or root-level JSON message fields by default, with an explicit opt-out. Valid IDs SHALL be nonzero hexadecimal strings of 32 and 16 characters respectively and SHALL be lowercase after normalization. Span correlation SHALL require a valid trace ID; trace-only correlation SHALL remain supported.

#### Scenario: Structured message context

- **WHEN** a journal message contains a JSON object with valid trace_id and span_id strings
- **THEN** the shipped record exposes lowercase correlation fields and retains its original message

#### Scenario: Trace without span

- **WHEN** a record contains a valid trace ID but no valid span ID
- **THEN** it exposes trace correlation without manufacturing a span ID

#### Scenario: Invalid context

- **WHEN** candidate IDs are all-zero, non-hexadecimal, the wrong length or not strings
- **THEN** they are not exposed as normalized correlation fields

#### Scenario: Explicit opt-out

- **WHEN** journal context normalization is disabled
- **THEN** the shipper does not parse or normalize correlation carriers

### Requirement: Normalization is conservative and lossless

Source-record correlation keys SHALL take precedence over message JSON, including when the source key is invalid. Parsing SHALL copy only supported correlation fields and SHALL NOT replace journal metadata or canonical identity. Missing, malformed or unsupported messages SHALL NOT cause record loss. Normalization SHALL occur before the shipper's persistent export buffer.

#### Scenario: Carrier conflict

- **WHEN** source fields and message JSON contain different trace IDs
- **THEN** the source field governs normalization and the original message remains unchanged

#### Scenario: Invalid preferred carrier

- **WHEN** an invalid source trace key accompanies a valid message trace key
- **THEN** the record remains without normalized trace correlation rather than silently substituting the lower-precedence value

#### Scenario: Malformed message

- **WHEN** a message is plain text, malformed JSON or a JSON value other than an object
- **THEN** it remains deliverable with its original message and journal metadata

#### Scenario: Metadata injection

- **WHEN** parsed JSON includes unit, host or timestamp fields alongside valid IDs
- **THEN** only the supported IDs are promoted and existing metadata remains unchanged

### Requirement: Correlation fields do not define storage identity

Generated log-stream keys and metric labels SHALL NOT contain trace or span IDs. Documentation SHALL distinguish correlation from authenticated identity and SHALL NOT promise that a referenced trace was retained or exported.

#### Scenario: Many request traces

- **WHEN** one unit emits records for many trace IDs
- **THEN** the generated stream identity remains independent of those request IDs
