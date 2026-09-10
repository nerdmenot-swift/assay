// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A name for every issue code the library can raise.
//
// `IssueCode` is a closed enum with a `.custom(String)` escape hatch, and the escape hatch
// is what every format module and every validation rule uses — an enum cannot grow across
// a module boundary. That is the right design and it had the wrong ergonomics: 85 distinct
// codes, four of which had a name, so `issue.code == .custom("union_unknown_variant")` was
// written from memory with no autocomplete, no typo protection and no place to read what
// params the code carries. "Match on `code`, never on `message`" is the documented advice;
// this file is what makes it pleasant to follow.
//
// One file rather than one extension per module, so the whole vocabulary is one page. The
// strings are the API — the JSON and problem-details renderers emit them, clients branch on
// them — and they do not change. `Messages.swift` still matches on the literals, which is
// why a code that is never rendered fails the message-coverage suite rather than compiling.
//===----------------------------------------------------------------------===//

extension IssueCode {

    // MARK: Decoding

    /// A string escape that is not one: a lone surrogate, a non-hex `\u` digit.
    /// `location` is the backslash. "contains an invalid escape sequence".
    public static let invalidEscape = IssueCode.custom("invalid_escape")
    /// `assayer_conversion_failed` — "the value was accepted by the schema but refused by its conversion".
    public static let assayerConversionFailed = IssueCode.custom("assayer_conversion_failed")
    /// `fallback_applied` — "fell back to the declared value".
    public static let fallbackApplied = IssueCode.custom("fallback_applied")
    /// `invalid_regex_pattern` — "the rule's pattern … is not a valid regular expression". Params: `pattern`.
    public static let invalidRegexPattern = IssueCode.custom("invalid_regex_pattern")
    /// `regex_unavailable` — "regular expressions are not available on this platform version".
    public static let regexUnavailable = IssueCode.custom("regex_unavailable")
    /// `unknown_variant`. Params: `options`.
    public static let unknownVariant = IssueCode.custom("unknown_variant")

    // MARK: Validation rules

    /// `empty` — "must not be empty".
    public static let empty = IssueCode.custom("empty")
    /// `invalid_email` — "must be a valid email address".
    public static let invalidEmail = IssueCode.custom("invalid_email")
    /// `invalid_hostname` — "must be a valid hostname".
    public static let invalidHostname = IssueCode.custom("invalid_hostname")
    /// `invalid_url` — "must be a valid URL".
    public static let invalidUrl = IssueCode.custom("invalid_url")
    /// `invalid_uuid` — "must be a valid UUID".
    public static let invalidUuid = IssueCode.custom("invalid_uuid")
    /// `missing_prefix` — "must start with \"…\"". Params: `prefix`.
    public static let missingPrefix = IssueCode.custom("missing_prefix")
    /// `missing_substring` — "must contain \"…\"". Params: `substring`.
    public static let missingSubstring = IssueCode.custom("missing_substring")
    /// `missing_suffix` — "must end with \"…\"". Params: `suffix`.
    public static let missingSuffix = IssueCode.custom("missing_suffix")
    /// `negative` — "must not be negative".
    public static let negative = IssueCode.custom("negative")
    /// `not_ascii` — "must contain only ASCII characters".
    public static let notAscii = IssueCode.custom("not_ascii")
    /// `not_finite` — "must be a finite number".
    public static let notFinite = IssueCode.custom("not_finite")
    /// `not_in_range` — "must be between … and …". Params: `maximum`, `minimum`.
    public static let notInRange = IssueCode.custom("not_in_range")
    /// `not_lowercased` — "must be lowercase".
    public static let notLowercased = IssueCode.custom("not_lowercased")
    /// `not_multiple` — "must be a multiple of …". Params: `multipleOf`.
    public static let notMultiple = IssueCode.custom("not_multiple")
    /// `not_negative` — "must be negative".
    public static let notNegative = IssueCode.custom("not_negative")
    /// `not_one_of` — "must be one of …". Params: `options`.
    public static let notOneOf = IssueCode.custom("not_one_of")
    /// `not_positive` — "must be positive".
    public static let notPositive = IssueCode.custom("not_positive")
    /// `not_trimmed` — "must not have leading or trailing whitespace".
    public static let notTrimmed = IssueCode.custom("not_trimmed")
    /// `not_unique` — "must not contain duplicates".
    public static let notUnique = IssueCode.custom("not_unique")
    /// `pattern_mismatch` — "must match the pattern …". Params: `pattern`.
    public static let patternMismatch = IssueCode.custom("pattern_mismatch")
    /// `too_large` — "must be at most …". Params: `maximum`.
    public static let tooLarge = IssueCode.custom("too_large")
    /// `too_small` — "must be at least …". Params: `minimum`.
    public static let tooSmall = IssueCode.custom("too_small")
    /// `wrong_count` — "must contain between … and … items". Params: `maximum`, `minimum`.
    public static let wrongCount = IssueCode.custom("wrong_count")
    /// `wrong_length` — "must be exactly … character… ? ". Params: `length`.
    public static let wrongLength = IssueCode.custom("wrong_length")

    // MARK: Dates

    /// `date_format_fallback` — "matched the fallback format …, ". Params: `matched`, `primary`.
    public static let dateFormatFallback = IssueCode.custom("date_format_fallback")
    /// `date_not_after` — "must be after …". Params: `bound`.
    public static let dateNotAfter = IssueCode.custom("date_not_after")
    /// `date_not_before` — "must be before …". Params: `bound`.
    public static let dateNotBefore = IssueCode.custom("date_not_before")
    /// `date_not_between` — "must be between … and …". Params: `maximum`, `minimum`.
    public static let dateNotBetween = IssueCode.custom("date_not_between")
    /// `invalid_date`. Params: `expected`, `reason`.
    public static let invalidDate = IssueCode.custom("invalid_date")
    /// `invalid_rule_date` — "the rule's date bound \"…\" is not a valid ISO-8601 date". Params: `bound`.
    public static let invalidRuleDate = IssueCode.custom("invalid_rule_date")

    // MARK: Unions

    /// `union_budget_exhausted` — "union backtracking exceeded … attempts (Limits.maxUnionAttempts)". Params: `maxUnionAttempts`.
    public static let unionBudgetExhausted = IssueCode.custom("union_budget_exhausted")
    /// `union_no_variant_matched`. Params: `closest`, `type`, `variants`.
    public static let unionNoVariantMatched = IssueCode.custom("union_no_variant_matched")
    /// `union_unknown_variant`. Params: `didYouMean`, `known`.
    public static let unionUnknownVariant = IssueCode.custom("union_unknown_variant")

    // MARK: Encoding

    /// `extras_key_collision` — "extras key \"…\" collides with a declared field". Params: `key`.
    public static let extrasKeyCollision = IssueCode.custom("extras_key_collision")
    /// `unknown_not_encodable`. Params: `type`.
    public static let unknownNotEncodable = IssueCode.custom("unknown_not_encodable")
    /// `unrepresentable_value` — "cannot be represented in … (…)". Params: `format`.
    public static let unrepresentableValue = IssueCode.custom("unrepresentable_value")

    // MARK: Content negotiation

    /// `missing_content_type` — "Content-Type …". Params: `reason`.
    public static let missingContentType = IssueCode.custom("missing_content_type")
    /// `unreadable_charset`. Params: `charset`, `reason`.
    public static let unreadableCharset = IssueCode.custom("unreadable_charset")
    /// `unsupported_media_type` — "media type … is not in the accepted list".
    public static let unsupportedMediaType = IssueCode.custom("unsupported_media_type")

    // MARK: Column sources

    /// `missing_column` — "is not a column in this source (expected …)". Params: `expected`.
    public static let missingColumn = IssueCode.custom("missing_column")

    // MARK: Mapped files (AssayFoundation)

    /// `cannot_map_file` — "could not open or map the file".
    public static let cannotMapFile = IssueCode.custom("cannot_map_file")

    // MARK: Property lists (AssayPlist)

    /// `plist_amplification` — "property list: …". Params: `reason`.
    public static let plistAmplification = IssueCode.custom("plist_amplification")
    /// `plist_bad_date`.
    public static let plistBadDate = IssueCode.custom("plist_bad_date")
    /// `plist_bad_magic`.
    public static let plistBadMagic = IssueCode.custom("plist_bad_magic")
    /// `plist_bad_marker`.
    public static let plistBadMarker = IssueCode.custom("plist_bad_marker")
    /// `plist_bad_offset`.
    public static let plistBadOffset = IssueCode.custom("plist_bad_offset")
    /// `plist_bad_real`.
    public static let plistBadReal = IssueCode.custom("plist_bad_real")
    /// `plist_bad_reference`.
    public static let plistBadReference = IssueCode.custom("plist_bad_reference")
    /// `plist_bad_root`.
    public static let plistBadRoot = IssueCode.custom("plist_bad_root")
    /// `plist_bad_string`.
    public static let plistBadString = IssueCode.custom("plist_bad_string")
    /// `plist_bad_trailer`.
    public static let plistBadTrailer = IssueCode.custom("plist_bad_trailer")
    /// `plist_bad_value`.
    public static let plistBadValue = IssueCode.custom("plist_bad_value")
    /// `plist_cycle` — "property list: …". Params: `reason`.
    public static let plistCycle = IssueCode.custom("plist_cycle")
    /// `plist_int_out_of_range`.
    public static let plistIntOutOfRange = IssueCode.custom("plist_int_out_of_range")
    /// `plist_int_too_wide`.
    public static let plistIntTooWide = IssueCode.custom("plist_int_too_wide")
    /// `plist_too_deep` — "property list nests deeper than … levels (Limits.maxDepth)". Params: `maxDepth`.
    public static let plistTooDeep = IssueCode.custom("plist_too_deep")
    /// `plist_truncated`.
    public static let plistTruncated = IssueCode.custom("plist_truncated")
    /// `plist_unpaired_key`.
    public static let plistUnpairedKey = IssueCode.custom("plist_unpaired_key")
    /// `plist_unrepresentable_key`.
    public static let plistUnrepresentableKey = IssueCode.custom("plist_unrepresentable_key")

    // MARK: TOML (AssayTOML)

    /// `toml_bad_date_time` — "invalid date-time".
    public static let tomlBadDateTime = IssueCode.custom("toml_bad_date_time")
    /// `toml_bad_escape` — "invalid escape sequence".
    public static let tomlBadEscape = IssueCode.custom("toml_bad_escape")
    /// `toml_bad_number` — "invalid number literal".
    public static let tomlBadNumber = IssueCode.custom("toml_bad_number")
    /// `toml_control_character` — "control characters must be escaped".
    public static let tomlControlCharacter = IssueCode.custom("toml_control_character")
    /// `toml_expected_equals` — "expected '=' after the key".
    public static let tomlExpectedEquals = IssueCode.custom("toml_expected_equals")
    /// `toml_expected_key` — "expected a key".
    public static let tomlExpectedKey = IssueCode.custom("toml_expected_key")
    /// `toml_expected_newline` — "expected a newline after the value".
    public static let tomlExpectedNewline = IssueCode.custom("toml_expected_newline")
    /// `toml_expected_value` — "expected a value".
    public static let tomlExpectedValue = IssueCode.custom("toml_expected_value")
    /// `toml_inline_table_closed` — "inline table '…' cannot be extended after it is defined". Params: `key`.
    public static let tomlInlineTableClosed = IssueCode.custom("toml_inline_table_closed")
    /// `toml_no_null` — "TOML has no null; the value cannot be encoded". Encoding only.
    public static let tomlNoNull = IssueCode.custom("toml_no_null")
    /// `toml_not_a_table` — "'…' is not a table and cannot be extended". Params: `key`.
    public static let tomlNotATable = IssueCode.custom("toml_not_a_table")
    /// `toml_redefined_table` — "table '…' is already defined". Params: `key`.
    public static let tomlRedefinedTable = IssueCode.custom("toml_redefined_table")
    /// `toml_root_not_a_table` — "a TOML document is a table; the root value is not". Encoding only.
    public static let tomlRootNotATable = IssueCode.custom("toml_root_not_a_table")
    /// `toml_unterminated_array` — "unterminated array; expected ',' or ']'".
    public static let tomlUnterminatedArray = IssueCode.custom("toml_unterminated_array")
    /// `toml_unterminated_inline_table` — "unterminated inline table; expected ',' or '}'".
    public static let tomlUnterminatedInlineTable = IssueCode.custom("toml_unterminated_inline_table")
    /// `toml_unterminated_string` — "unterminated string".
    public static let tomlUnterminatedString = IssueCode.custom("toml_unterminated_string")
    /// `toml_unterminated_table_header` — "expected ']' closing the table header".
    public static let tomlUnterminatedTableHeader = IssueCode.custom("toml_unterminated_table_header")

    // MARK: YAML (AssayYAML)

    /// `yaml_anchor_on_alias` — "an anchor cannot be placed on an alias (`&a *b`); an alias refers to an anchored node and is not a node of its own".
    public static let yamlAnchorOnAlias = IssueCode.custom("yaml_anchor_on_alias")
    /// `yaml_bad_escape` — "invalid escape sequence".
    public static let yamlBadEscape = IssueCode.custom("yaml_bad_escape")
    /// `yaml_empty_stream` — "the stream contains no documents".
    public static let yamlEmptyStream = IssueCode.custom("yaml_empty_stream")
    /// `yaml_expansion_limit` — "alias expansion limit exceeded".
    public static let yamlExpansionLimit = IssueCode.custom("yaml_expansion_limit")
    /// `yaml_expected_colon` — "expected ':' after mapping key".
    public static let yamlExpectedColon = IssueCode.custom("yaml_expected_colon")
    /// `yaml_expected_value_indicator` — "expected ':' introducing the value".
    public static let yamlExpectedValueIndicator = IssueCode.custom("yaml_expected_value_indicator")
    /// `yaml_multiple_documents` — "the stream contains multiple documents; use parseAll".
    public static let yamlMultipleDocuments = IssueCode.custom("yaml_multiple_documents")
    /// `yaml_undefined_alias` — "alias refers to an undefined anchor".
    public static let yamlUndefinedAlias = IssueCode.custom("yaml_undefined_alias")
    /// `yaml_unexpected_in_flow` — "unexpected character in a flow collection; expected ',' or a closing bracket".
    public static let yamlUnexpectedInFlow = IssueCode.custom("yaml_unexpected_in_flow")
    /// `yaml_unrepresentable_key` — "a mapping key is not a plain scalar; parse to YAML.Node instead".
    public static let yamlUnrepresentableKey = IssueCode.custom("yaml_unrepresentable_key")
    /// `yaml_unterminated_flow_mapping` — "unterminated flow mapping".
    public static let yamlUnterminatedFlowMapping = IssueCode.custom("yaml_unterminated_flow_mapping")
    /// `yaml_unterminated_flow_sequence` — "unterminated flow sequence".
    public static let yamlUnterminatedFlowSequence = IssueCode.custom("yaml_unterminated_flow_sequence")
    /// `yaml_unterminated_quoted_scalar` — "unterminated quoted scalar".
    public static let yamlUnterminatedQuotedScalar = IssueCode.custom("yaml_unterminated_quoted_scalar")

    // MARK: XML (AssayXML)

    /// `xml_bad_attribute_name` — "invalid attribute name".
    public static let xmlBadAttributeName = IssueCode.custom("xml_bad_attribute_name")
    /// `xml_bad_character_reference` — "invalid character reference".
    public static let xmlBadCharacterReference = IssueCode.custom("xml_bad_character_reference")
    /// `xml_bad_name` — "invalid name".
    public static let xmlBadName = IssueCode.custom("xml_bad_name")
    /// `xml_bad_pi_target` — "invalid processing instruction target".
    public static let xmlBadPiTarget = IssueCode.custom("xml_bad_pi_target")
    /// `xml_entity_expansion_limit` — "entity expansion limit exceeded".
    public static let xmlEntityExpansionLimit = IssueCode.custom("xml_entity_expansion_limit")
    /// `xml_expected_element` — "expected an element".
    public static let xmlExpectedElement = IssueCode.custom("xml_expected_element")
    /// `xml_expected_equals` — "expected '=' after attribute name".
    public static let xmlExpectedEquals = IssueCode.custom("xml_expected_equals")
    /// `xml_external_dtd_ignored` — "external DTD subset ignored (never fetched)".
    public static let xmlExternalDtdIgnored = IssueCode.custom("xml_external_dtd_ignored")
    /// `xml_external_entity_ignored` — "external entity ignored (never fetched)".
    public static let xmlExternalEntityIgnored = IssueCode.custom("xml_external_entity_ignored")
    /// `xml_mismatched_tag` — "closing tag does not match".
    public static let xmlMismatchedTag = IssueCode.custom("xml_mismatched_tag")
    /// `xml_no_root` — "document has no root element".
    public static let xmlNoRoot = IssueCode.custom("xml_no_root")
    /// `xml_raw_lt_in_attribute` — "'<' is not allowed in an attribute value".
    public static let xmlRawLtInAttribute = IssueCode.custom("xml_raw_lt_in_attribute")
    /// `xml_recursive_entity` — "entity &…; refers to itself". Params: `entity`.
    public static let xmlRecursiveEntity = IssueCode.custom("xml_recursive_entity")
    /// `xml_root_mismatch` — "root element must be <…>, found <…>". Params: `expected`.
    public static let xmlRootMismatch = IssueCode.custom("xml_root_mismatch")
    /// `xml_unclosed_element` — "element is never closed".
    public static let xmlUnclosedElement = IssueCode.custom("xml_unclosed_element")
    /// `xml_undeclared_entity` — "reference to an undeclared entity".
    public static let xmlUndeclaredEntity = IssueCode.custom("xml_undeclared_entity")
    /// `xml_unquoted_attribute` — "attribute value must be quoted".
    public static let xmlUnquotedAttribute = IssueCode.custom("xml_unquoted_attribute")
    /// `xml_unterminated_attribute` — "unterminated attribute value".
    public static let xmlUnterminatedAttribute = IssueCode.custom("xml_unterminated_attribute")
    /// `xml_unterminated_cdata` — "unterminated CDATA section".
    public static let xmlUnterminatedCdata = IssueCode.custom("xml_unterminated_cdata")
    /// `xml_unterminated_comment` — "unterminated comment".
    public static let xmlUnterminatedComment = IssueCode.custom("xml_unterminated_comment")
    /// `xml_unterminated_doctype` — "unterminated DOCTYPE".
    public static let xmlUnterminatedDoctype = IssueCode.custom("xml_unterminated_doctype")
    /// `xml_unterminated_entity` — "unterminated entity reference".
    public static let xmlUnterminatedEntity = IssueCode.custom("xml_unterminated_entity")
    /// `xml_unterminated_pi` — "unterminated processing instruction".
    public static let xmlUnterminatedPi = IssueCode.custom("xml_unterminated_pi")
    /// `xml_unterminated_tag` — "unterminated tag".
    public static let xmlUnterminatedTag = IssueCode.custom("xml_unterminated_tag")
}
