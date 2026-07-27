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
    case "cannot_map_file": return "could not open or map the file"
    case "fallback_applied": return "fell back to the declared value"
    default: return nil
    }
}

extension Issue {
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
                let unit = params["unit"]?.displayString ?? ""
                return "must be at least \(m.displayString)\(unit.isEmpty ? "" : " \(unit)")"
            }
            return "is too small"
        case .custom("too_large"):
            if let m = params["maximum"] {
                let unit = params["unit"]?.displayString ?? ""
                return "must be at most \(m.displayString)\(unit.isEmpty ? "" : " \(unit)")"
            }
            return "is too large"
        case .custom("not_in_range"):
            if let lo = params["minimum"], let hi = params["maximum"] {
                return "must be between \(lo.displayString) and \(hi.displayString)"
            }
            return "is out of range"
        case .custom("wrong_length"):
            if let n = params["length"] {
                return "must be exactly \(n.displayString) characters"
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
extension IssueCode {
    /// The code `@Fallback` warnings carry.
    public static let fallbackApplied = IssueCode.custom("fallback_applied")
}
