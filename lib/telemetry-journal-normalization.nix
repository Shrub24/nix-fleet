# Conservative journal trace-context normalization, rendered as the `source` of
# a Vector remap transform.
#
# Carriers are exact `trace_id` / `span_id` keys at the record root or at the
# root of a JSON object in `message`. Root keys win over message JSON,
# including when the root key is invalid, so an invalid root value omits the
# field rather than silently substituting a lower-precedence one. Only the
# allowlisted IDs are copied; the message never overwrites identity,
# timestamps, unit or service fields.
{ lib }:
let
  # Validity guard for the coerced local candidate: a nonzero hexadecimal
  # string of exactly `length` characters. Coercion makes absent and non-string
  # values fail the same guard without aborting the record.
  guard =
    length:
    "strlen(candidate) == ${toString length} && match(candidate, r'^[0-9a-fA-F]+$') && !match(candidate, r'^0+$')";

  inspect = field: length: [
    "candidate = string(${field}) ?? \"\""
    "candidateValid = ${guard length}"
  ];

  indent = depth: line: lib.concatStrings (lib.replicate depth " ") + line;

  resolveLines =
    field: target: length:
    [ "if exists(.${field}) {" ]
    ++ map (indent 2) (inspect ".${field}" length)
    ++ [
      "  if candidateValid { ${target} = downcase(candidate) } else { del(${target}) }"
      "} else {"
      "  candidateValid = false"
      "  if is_object(parsed) && exists(parsed.${field}) {"
    ]
    ++ map (indent 4) (inspect "parsed.${field}" length)
    ++ [
      "    if candidateValid { ${target} = downcase(candidate) }"
      "  }"
      "}"
    ];

  # A root span has its own precedence decision. Retaining presence separately
  # ensures that deleting an invalid root span never enables message fallback.
  spanLines = [
    "spanRootPresent = exists(.span_id)"
    "if !exists(.trace_id) {"
    "  del(.span_id)"
    "} else {"
    "  if spanRootPresent {"
  ]
  ++ map (indent 4) (inspect ".span_id" 16)
  ++ [
    "    if candidateValid { .span_id = downcase(candidate) } else { del(.span_id) }"
    "  }"
    "  if !spanRootPresent && is_object(parsed) && exists(parsed.span_id) {"
  ]
  ++ map (indent 4) (inspect "parsed.span_id" 16)
  ++ [
    "    if candidateValid { .span_id = downcase(candidate) }"
    "  }"
    "}"
  ];
in
rec {
  # These are VRL local variables, not event fields: arbitrary journal fields
  # named parsed/candidate/etc. survive untouched.
  remapSource = lib.concatLines (
    [
      "parsed = parse_json(.message) ?? null"
      "if !is_object(parsed) { parsed = null }"
    ]
    ++ resolveLines "trace_id" ".trace_id" 32
    ++ spanLines
  );

  identitySource =
    fields:
    lib.concatLines (lib.mapAttrsToList (key: value: ".${key} = ${builtins.toJSON value}") fields);
}
