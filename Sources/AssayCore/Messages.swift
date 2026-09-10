// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Messages are derived, never stored. docs/EXPERIENCE.md §3.
//
// An issue carries a code and a parameter dictionary — Ecto's {template, params} model —
// and the English sentence is produced here, on demand. That is the difference between a
// library that can be localised and one that can only ever speak English: a downstream
// consumer matches on `issue.code` and renders its own words, or calls `.message` and
// gets these.
//
// The sentences are predicate-shaped ("is required", "must be at least 1") so that the
// renderer can prefix the path: "name is required", "replicas must be at least 1".
//===----------------------------------------------------------------------===//

extension IssueCode {
    /// The stable machine-readable string for this code. Matches the JSON and
    /// problem-details renders; downstream clients branch on this, never on `message`.
    public var codeString: String {
        switch self {
        case .missing: return "missing"
        case .typeMismatch: return "type_mismatch"
        case .malformedDocument: return "malformed_document"
        case .numberOverflow: return "number_overflow"
        case .invalidUTF8: return "invalid_utf8"
        case .unknownKey: return "unknown_key"
        case .duplicateKey: return "duplicate_key"
        case .depthExceeded: return "depth_exceeded"
        case .tooManyBytes: return "too_many_bytes"
        case .trailingContent: return "trailing_content"
        case .custom(let s): return s
        }
    }
}

extension IssueValue {
    /// Rendered for interpolation into a message.
    public var displayString: String {
        switch self {
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        }
    }
}

/// Messages the library's own internal codes render as. A `.custom` code that is not in
/// this table is treated as the message itself — that is the `issues.add(.custom("must be
/// a company address"))` case from EXPERIENCE.md §3, where forcing the author of a one-off
/// rule to invent a code would be obnoxious.
@usableFromInline
func internalCustomMessage(_ code: String) -> String? {
    switch code {
    case "xml_no_root": return "document has no root element"
    case "xml_expected_element": return "expected an element"
    case "xml_bad_name": return "invalid name"
    case "xml_bad_attribute_name": return "invalid attribute name"
    case "xml_expected_equals": return "expected '=' after attribute name"
    case "xml_unterminated_tag": return "unterminated tag"
    case "xml_unclosed_element": return "element is never closed"
    case "xml_mismatched_tag": return "closing tag does not match"
    case "xml_unterminated_comment": return "unterminated comment"
    case "xml_unterminated_cdata": return "unterminated CDATA section"
    case "xml_unterminated_pi": return "unterminated processing instruction"
    case "xml_bad_pi_target": return "invalid processing instruction target"
    case "xml_unquoted_attribute": return "attribute value must be quoted"
    case "xml_raw_lt_in_attribute": return "'<' is not allowed in an attribute value"
    case "xml_unterminated_attribute": return "unterminated attribute value"
    case "xml_unterminated_entity": return "unterminated entity reference"
    case "xml_bad_character_reference": return "invalid character reference"
    case "xml_undeclared_entity": return "reference to an undeclared entity"
    case "xml_entity_expansion_limit": return "entity expansion limit exceeded"
    case "xml_unterminated_doctype": return "unterminated DOCTYPE"
    case "xml_external_dtd_ignored": return "external DTD subset ignored (never fetched)"
    case "xml_external_entity_ignored": return "external entity ignored (never fetched)"
    case "yaml_empty_stream": return "the stream contains no documents"
    case "yaml_multiple_documents": return "the stream contains multiple documents; use parseAll"
    case "yaml_undefined_alias": return "alias refers to an undefined anchor"
    case "yaml_expansion_limit": return "alias expansion limit exceeded"
    case "yaml_expected_colon": return "expected ':' after mapping key"
    case "yaml_expected_value_indicator": return "expected ':' introducing the value"
    case "yaml_unexpected_in_flow":
        return "unexpected character in a flow collection; expected ',' or a closing bracket"
    case "yaml_unterminated_flow_sequence": return "unterminated flow sequence"
    case "yaml_unterminated_flow_mapping": return "unterminated flow mapping"
    case "yaml_unterminated_quoted_scalar": return "unterminated quoted scalar"
    case "yaml_bad_escape": return "invalid escape sequence"
    case "yaml_unrepresentable_key":
        return "a mapping key is not a plain scalar; parse to YAML.Node instead"
    case "toml_expected_key": return "expected a key"
    case "toml_expected_equals": return "expected '=' after the key"
    case "toml_expected_value": return "expected a value"
    case "toml_expected_newline": return "expected a newline after the value"
    case "toml_unterminated_string": return "unterminated string"
    case "toml_bad_escape": return "invalid escape sequence"
    case "toml_control_character": return "control characters must be escaped"
    case "toml_bad_number": return "invalid number literal"
    case "toml_bad_date_time": return "invalid date-time"
    case "toml_unterminated_array": return "unterminated array; expected ',' or ']'"
    case "toml_unterminated_inline_table": return "unterminated inline table; expected ',' or '}'"
    case "toml_unterminated_table_header": return "expected ']' closing the table header"
    case "toml_no_null": return "TOML has no null; the value cannot be encoded"
    case "toml_root_not_a_table": return "a TOML document is a table; the root value is not"
    case "cannot_map_file": return "could not open or map the file"
    case "invalid_escape": return "contains an invalid escape sequence"
    case "fallback_applied": return "fell back to the declared value"
    default: return nil
    }
}

extension Issue {
    /// `" characters"`, `" character"`, `" items"`, `" item"`, or nothing — the unit a size
    /// rule carries, agreeing in number with the bound. Found by the printing tests:
    /// "must be at least 1 characters".
    func unitSuffix(_ bound: IssueValue) -> String {
        guard let unit = params["unit"]?.displayString, !unit.isEmpty else { return "" }
        if bound == .int(1), unit.hasSuffix("s") { return " " + String(unit.dropLast()) }
        return " " + unit
    }

    /// The English sentence, derived from `code` and `params` on demand.
    ///
    /// Predicate-shaped, so the renderer can write `"\(path) \(message)"`. Match on
    /// `code`, never on this — the wording is not part of the API contract.
    public var message: String {
        // An explicit message override — from a rule's string literal or `or:` — beats
        // the derived sentence for any code. EXPERIENCE.md §5: the literal "overrides the
        // message for every other rule in the same attribute".
        if let m = params["message"] { return m.displayString }
        switch code {
        case .missing:
            return "is required"

        case .typeMismatch:
            let expected = params["expected"]?.displayString ?? "a different type"
            let article = "aeiou".contains(expected.first ?? "x") ? "an" : "a"
            if let r = received {
                return "must be \(article) \(expected), found \(r)"
            }
            return "must be \(article) \(expected)"

        case .malformedDocument:
            return "is not a well-formed document"

        case .numberOverflow:
            return "number is out of range"

        case .invalidUTF8:
            if let off = params["offset"] {
                return "input is not valid UTF-8 (byte \(off.displayString))"
            }
            return "input is not valid UTF-8"

        case .unknownKey:
            var m = "unknown key"
            if let r = received { m += " \"\(r)\"" }
            if let hint = params["didYouMean"] {
                m += "; did you mean \"\(hint.displayString)\"?"
            }
            return m

        case .duplicateKey:
            if let r = received { return "duplicate key \"\(r)\"" }
            return "duplicate key"

        case .depthExceeded:
            if let d = params["maxDepth"] {
                return "nesting exceeds the maximum depth of \(d.displayString)"
            }
            return "nesting exceeds the maximum depth"

        case .tooManyBytes:
            if let m = params["maxBytes"], case .int(let n) = m, n != .max {
                return "input exceeds the maximum size of \(n) bytes"
            }
            return "input exceeds the maximum size"

        case .trailingContent:
            return "unexpected content after the end of the document"

        // Validation codes, emitted by the rule engine. Kept here rather than beside the
        // rules so every rendered sentence in the library lives in one reviewable file.
        case .custom("too_small"):
            if let m = params["minimum"] {
                return "must be at least \(m.displayString)\(unitSuffix(m))"
            }
            return "is too small"
        case .custom("too_large"):
            if let m = params["maximum"] {
                return "must be at most \(m.displayString)\(unitSuffix(m))"
            }
            return "is too large"
        case .custom("not_in_range"):
            if let lo = params["minimum"], let hi = params["maximum"] {
                return "must be between \(lo.displayString) and \(hi.displayString)"
            }
            return "is out of range"
        case .custom("wrong_length"):
            if let n = params["length"] {
                return "must be exactly \(n.displayString) character\(n == .int(1) ? "" : "s")"
            }
            return "has the wrong length"
        case .custom("wrong_count"):
            if let lo = params["minimum"], let hi = params["maximum"] {
                return "must contain between \(lo.displayString) and \(hi.displayString) items"
            }
            return "has the wrong number of items"
        case .custom("empty"): return "must not be empty"
        case .custom("invalid_email"): return "must be a valid email address"
        case .custom("invalid_url"): return "must be a valid URL"
        case .custom("invalid_uuid"): return "must be a valid UUID"
        case .custom("invalid_hostname"): return "must be a valid hostname"
        case .custom("not_ascii"): return "must contain only ASCII characters"
        case .custom("pattern_mismatch"):
            if let p = params["pattern"] {
                return "must match the pattern \(p.displayString)"
            }
            return "does not match the required pattern"
        case .custom("invalid_regex_pattern"):
            if let p = params["pattern"] {
                return "the rule's pattern \(p.displayString) is not a valid regular expression"
            }
            return "the rule's pattern is not a valid regular expression"
        case .custom("regex_unavailable"):
            return "regular expressions are not available on this platform version"
        case .custom("missing_prefix"):
            if let p = params["prefix"] { return "must start with \"\(p.displayString)\"" }
            return "is missing a required prefix"
        case .custom("missing_suffix"):
            if let s = params["suffix"] { return "must end with \"\(s.displayString)\"" }
            return "is missing a required suffix"
        case .custom("missing_substring"):
            if let s = params["substring"] { return "must contain \"\(s.displayString)\"" }
            return "is missing required content"
        case .custom("not_one_of"):
            if let opts = params["options"] { return "must be one of \(opts.displayString)" }
            return "is not an allowed value"
        case .custom("not_trimmed"): return "must not have leading or trailing whitespace"
        case .custom("not_lowercased"): return "must be lowercase"
        case .custom("not_positive"): return "must be positive"
        case .custom("not_negative"): return "must be negative"
        case .custom("negative"): return "must not be negative"
        case .custom("not_multiple"):
            if let m = params["multipleOf"] {
                return "must be a multiple of \(m.displayString)"
            }
            return "is not an allowed multiple"
        case .custom("not_finite"): return "must be a finite number"
        case .custom("not_unique"): return "must not contain duplicates"
        case .custom("unknown_variant"):
            var m = "is not a recognised value"
            if let r = received { m = "\"\(r)\" is not a recognised value" }
            if let opts = params["options"] {
                m += "; must be one of \(opts.displayString)"
            }
            return m

        case .custom("invalid_date"):
            // "must be an ISO-8601 date — day 31 is out of range for 2026-02".
            // The reason names the field and the position; `offset` is also in params
            // for a renderer that wants to place its own caret.
            var m = "must be a"
            if let e = params["expected"] {
                let first = e.displayString.first ?? "x"
                m = "aeiouAEIOU".contains(first) ? "must be an" : "must be a"
                m += " \(e.displayString)"
            } else {
                m += " valid date"
            }
            if let r = params["reason"] { m += " — \(r.displayString)" }
            return m
        case .custom("date_format_fallback"):
            if let matched = params["matched"], let primary = params["primary"] {
                return "matched the fallback format \(matched.displayString), "
                    + "not the primary \(primary.displayString)"
            }
            return "matched a fallback date format"
        case .custom("date_not_before"):
            if let b = params["bound"] { return "must be before \(b.displayString)" }
            return "is too late"
        case .custom("date_not_after"):
            if let b = params["bound"] { return "must be after \(b.displayString)" }
            return "is too early"
        case .custom("date_not_between"):
            if let lo = params["minimum"], let hi = params["maximum"] {
                return "must be between \(lo.displayString) and \(hi.displayString)"
            }
            return "is outside the allowed range"
        case .custom("unknown_not_encodable"):
            let t = params["type"]?.displayString ?? "this enum"
            var m = "was decoded as an unrecognised \(t) value"
            if let r = received { m += " (\"\(r)\")" }
            m += " and cannot be encoded; add @Unknown(roundTrips: true) if writing it "
            m += "back is intended"
            return m
        case .custom("missing_column"):
            let e = params["expected"]?.displayString ?? "a column"
            return "is not a column in this source (expected \(e))"
        case .custom("unrepresentable_value"):
            let fmt = params["format"]?.displayString ?? "this format"
            if let r = received {
                return "cannot be represented in \(fmt) (\(r))"
            }
            return "cannot be represented in \(fmt)"
        case .custom("extras_key_collision"):
            if let k = params["key"] {
                return "extras key \"\(k.displayString)\" collides with a declared field"
            }
            return "an extras key collides with a declared field"
        case .custom("invalid_rule_date"):
            if let b = params["bound"] {
                return "the rule's date bound \"\(b.displayString)\" is not a valid ISO-8601 date"
            }
            return "the rule's date bound is not a valid ISO-8601 date"

        // Unions. docs/UNIONS.md §2. Found rendering as their identifiers on 2026-09-10,
        // the day the message-coverage test started reading the names file instead of a
        // hand-kept list.
        case .custom("union_unknown_variant"):
            let known = params["known"]?.displayString ?? ""
            var m = known.isEmpty ? "names an unknown variant" : "must be one of \(known)"
            if let r = received { m += ", found \(r)" }
            if let d = params["didYouMean"]?.displayString { m += "; did you mean \"\(d)\"?" }
            return m
        case .custom("union_no_variant_matched"):
            let type = params["type"]?.displayString ?? "the union"
            let variants = params["variants"]?.displayString ?? ""
            var m = "did not match any variant of \(type)"
            if !variants.isEmpty { m += " (\(variants))" }
            if let c = params["closest"]?.displayString, !c.isEmpty {
                m += "; closest was \(c), whose issues follow"
            }
            return m
        case .custom("union_budget_exhausted"):
            if let n = params["maxUnionAttempts"] {
                return "union backtracking exceeded \(n.displayString) attempts (Limits.maxUnionAttempts)"
            }
            return "union backtracking budget exhausted"

        // Content negotiation. WireFormat.swift.
        case .custom("missing_content_type"):
            if let r = params["reason"]?.displayString { return "Content-Type \(r)" }
            return "Content-Type is missing or unparseable"
        case .custom("unsupported_media_type"):
            if let r = received { return "media type \(r) is not in the accepted list" }
            return "media type is not in the accepted list"
        case .custom("unreadable_charset"):
            var m = "charset"
            if let c = params["charset"]?.displayString { m += " \(c)" }
            m += " cannot be read without transcoding"
            if let r = params["reason"]?.displayString { m += " — \(r)" }
            return m

        // Property lists, both flavours. Every one carries the parser's own `reason`.
        case .custom("plist_bad_root"), .custom("plist_bad_value"), .custom("plist_bad_marker"),
             .custom("plist_unpaired_key"), .custom("plist_bad_date"), .custom("plist_bad_real"),
             .custom("plist_bad_string"), .custom("plist_bad_magic"), .custom("plist_bad_trailer"),
             .custom("plist_bad_offset"), .custom("plist_bad_reference"), .custom("plist_truncated"),
             .custom("plist_int_too_wide"), .custom("plist_int_out_of_range"),
             .custom("plist_unrepresentable_key"):
            if let r = params["reason"]?.displayString { return "property list: \(r)" }
            return "property list is malformed"
        case .custom("plist_cycle"):
            if let r = params["reason"]?.displayString { return "property list: \(r)" }
            return "property list contains a reference cycle"
        case .custom("plist_amplification"):
            if let r = params["reason"]?.displayString { return "property list: \(r)" }
            return "property list expands past the node budget"
        case .custom("plist_too_deep"):
            if let d = params["maxDepth"] {
                return "property list nests deeper than \(d.displayString) levels (Limits.maxDepth)"
            }
            return "property list nests too deeply"

        // The rest.
        case .custom("assayer_conversion_failed"):
            return "the value was accepted by the schema but refused by its conversion"
        case .custom("xml_recursive_entity"):
            if let e = params["entity"]?.displayString { return "entity &\(e); refers to itself" }
            return "an entity refers to itself"
        case .custom("xml_root_mismatch"):
            let expected = params["expected"]?.displayString ?? ""
            if let r = received { return "root element must be <\(expected)>, found <\(r)>" }
            return "root element must be <\(expected)>"
        case .custom("alias_matched"):
            if let a = params["alias"]?.displayString { return "was read from its alias \"\(a)\"" }
            return "was read from an alias"
        case .custom("toml_redefined_table"):
            if let k = params["key"]?.displayString { return "table '\(k)' is already defined" }
            return "table is already defined"
        case .custom("toml_inline_table_closed"):
            if let k = params["key"]?.displayString { return "inline table '\(k)' cannot be extended after it is defined" }
            return "an inline table cannot be extended after it is defined"
        case .custom("toml_not_a_table"):
            if let k = params["key"]?.displayString { return "'\(k)' is not a table and cannot be extended" }
            return "the key is not a table and cannot be extended"
        case .custom("yaml_anchor_on_alias"):
            return "an anchor cannot be placed on an alias (`&a *b`); an alias refers to an anchored node and is not a node of its own"

        case .custom(let s):
            // An internal code renders as a sentence; otherwise — the EXPERIENCE.md §3
            // case — a one-off custom check whose string IS the message.
            return internalCustomMessage(s) ?? s
        }
    }
}

extension Warning {
    public var message: String {
        // A warning is an Issue-shaped thing with softer consequences; reuse the table.
        Issue(code: code, path: path, params: params,
              received: params["received"]?.displayString, location: location).message
    }
}

// The @Fallback warning. Kept here with every other rendered sentence.

// MARK: - Printing
//
// What `print(issue)` and `"\(issue)"` show. Added 2026-09-10 by the audit that found the
// library whose headline is error reporting printed `Issue(code: AssayCore.IssueCode…` —
// the synthesized reflection dump — anywhere a developer sees a value without asking for
// it: string interpolation, a failed `#expect`, a log line.
//
// The shape is the renderer's own one-line form, `path message`, with no source location:
// a bare `Issue` has no document to point into. `render(.plain)` on the `Diagnosis` or the
// `AssayError` is where the carets are.

extension Issue: CustomStringConvertible {
    public var description: String {
        path.isEmpty ? message : "\(path.pathDescription) \(message)"
    }
}

extension Warning: CustomStringConvertible {
    public var description: String {
        path.isEmpty ? message : "\(path.pathDescription) \(message)"
    }
}
