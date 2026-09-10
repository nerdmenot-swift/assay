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
    /// `location` is the backslash.
    public static let invalidEscape = IssueCode.custom("invalid_escape")
    public static let assayerConversionFailed = IssueCode.custom("assayer_conversion_failed")
    public static let fallbackApplied = IssueCode.custom("fallback_applied")
    public static let invalidRegexPattern = IssueCode.custom("invalid_regex_pattern")
    public static let regexUnavailable = IssueCode.custom("regex_unavailable")
    public static let unknownVariant = IssueCode.custom("unknown_variant")

    // MARK: Validation rules

    public static let empty = IssueCode.custom("empty")
    public static let invalidEmail = IssueCode.custom("invalid_email")
    public static let invalidHostname = IssueCode.custom("invalid_hostname")
    public static let invalidUrl = IssueCode.custom("invalid_url")
    public static let invalidUuid = IssueCode.custom("invalid_uuid")
    public static let missingPrefix = IssueCode.custom("missing_prefix")
    public static let missingSubstring = IssueCode.custom("missing_substring")
    public static let missingSuffix = IssueCode.custom("missing_suffix")
    public static let negative = IssueCode.custom("negative")
    public static let notAscii = IssueCode.custom("not_ascii")
    public static let notFinite = IssueCode.custom("not_finite")
    public static let notInRange = IssueCode.custom("not_in_range")
    public static let notLowercased = IssueCode.custom("not_lowercased")
    public static let notMultiple = IssueCode.custom("not_multiple")
    public static let notNegative = IssueCode.custom("not_negative")
    public static let notOneOf = IssueCode.custom("not_one_of")
    public static let notPositive = IssueCode.custom("not_positive")
    public static let notTrimmed = IssueCode.custom("not_trimmed")
    public static let notUnique = IssueCode.custom("not_unique")
    public static let patternMismatch = IssueCode.custom("pattern_mismatch")
    public static let tooLarge = IssueCode.custom("too_large")
    public static let tooSmall = IssueCode.custom("too_small")
    public static let wrongCount = IssueCode.custom("wrong_count")
    public static let wrongLength = IssueCode.custom("wrong_length")

    // MARK: Dates

    public static let dateFormatFallback = IssueCode.custom("date_format_fallback")
    public static let dateNotAfter = IssueCode.custom("date_not_after")
    public static let dateNotBefore = IssueCode.custom("date_not_before")
    public static let dateNotBetween = IssueCode.custom("date_not_between")
    public static let invalidDate = IssueCode.custom("invalid_date")
    public static let invalidRuleDate = IssueCode.custom("invalid_rule_date")

    // MARK: Unions

    public static let unionBudgetExhausted = IssueCode.custom("union_budget_exhausted")
    public static let unionNoVariantMatched = IssueCode.custom("union_no_variant_matched")
    public static let unionUnknownVariant = IssueCode.custom("union_unknown_variant")

    // MARK: Encoding

    public static let extrasKeyCollision = IssueCode.custom("extras_key_collision")
    public static let unknownNotEncodable = IssueCode.custom("unknown_not_encodable")
    public static let unrepresentableValue = IssueCode.custom("unrepresentable_value")

    // MARK: Content negotiation

    public static let missingContentType = IssueCode.custom("missing_content_type")
    public static let unreadableCharset = IssueCode.custom("unreadable_charset")
    public static let unsupportedMediaType = IssueCode.custom("unsupported_media_type")

    // MARK: Column sources

    public static let missingColumn = IssueCode.custom("missing_column")

    // MARK: Mapped files (AssayFoundation)

    public static let cannotMapFile = IssueCode.custom("cannot_map_file")

    // MARK: Property lists (AssayPlist)

    public static let plistAmplification = IssueCode.custom("plist_amplification")
    public static let plistBadDate = IssueCode.custom("plist_bad_date")
    public static let plistBadMagic = IssueCode.custom("plist_bad_magic")
    public static let plistBadMarker = IssueCode.custom("plist_bad_marker")
    public static let plistBadOffset = IssueCode.custom("plist_bad_offset")
    public static let plistBadReal = IssueCode.custom("plist_bad_real")
    public static let plistBadReference = IssueCode.custom("plist_bad_reference")
    public static let plistBadRoot = IssueCode.custom("plist_bad_root")
    public static let plistBadString = IssueCode.custom("plist_bad_string")
    public static let plistBadTrailer = IssueCode.custom("plist_bad_trailer")
    public static let plistBadValue = IssueCode.custom("plist_bad_value")
    public static let plistCycle = IssueCode.custom("plist_cycle")
    public static let plistIntOutOfRange = IssueCode.custom("plist_int_out_of_range")
    public static let plistIntTooWide = IssueCode.custom("plist_int_too_wide")
    public static let plistTooDeep = IssueCode.custom("plist_too_deep")
    public static let plistTruncated = IssueCode.custom("plist_truncated")
    public static let plistUnpairedKey = IssueCode.custom("plist_unpaired_key")
    public static let plistUnrepresentableKey = IssueCode.custom("plist_unrepresentable_key")

    // MARK: YAML (AssayYAML)

    public static let yamlAnchorOnAlias = IssueCode.custom("yaml_anchor_on_alias")
    public static let yamlBadEscape = IssueCode.custom("yaml_bad_escape")
    public static let yamlEmptyStream = IssueCode.custom("yaml_empty_stream")
    public static let yamlExpansionLimit = IssueCode.custom("yaml_expansion_limit")
    public static let yamlExpectedColon = IssueCode.custom("yaml_expected_colon")
    public static let yamlExpectedValueIndicator = IssueCode.custom("yaml_expected_value_indicator")
    public static let yamlMultipleDocuments = IssueCode.custom("yaml_multiple_documents")
    public static let yamlUndefinedAlias = IssueCode.custom("yaml_undefined_alias")
    public static let yamlUnexpectedInFlow = IssueCode.custom("yaml_unexpected_in_flow")
    public static let yamlUnrepresentableKey = IssueCode.custom("yaml_unrepresentable_key")
    public static let yamlUnterminatedFlowMapping = IssueCode.custom("yaml_unterminated_flow_mapping")
    public static let yamlUnterminatedFlowSequence = IssueCode.custom("yaml_unterminated_flow_sequence")
    public static let yamlUnterminatedQuotedScalar = IssueCode.custom("yaml_unterminated_quoted_scalar")

    // MARK: XML (AssayXML)

    public static let xmlBadAttributeName = IssueCode.custom("xml_bad_attribute_name")
    public static let xmlBadCharacterReference = IssueCode.custom("xml_bad_character_reference")
    public static let xmlBadName = IssueCode.custom("xml_bad_name")
    public static let xmlBadPiTarget = IssueCode.custom("xml_bad_pi_target")
    public static let xmlEntityExpansionLimit = IssueCode.custom("xml_entity_expansion_limit")
    public static let xmlExpectedElement = IssueCode.custom("xml_expected_element")
    public static let xmlExpectedEquals = IssueCode.custom("xml_expected_equals")
    public static let xmlExternalDtdIgnored = IssueCode.custom("xml_external_dtd_ignored")
    public static let xmlExternalEntityIgnored = IssueCode.custom("xml_external_entity_ignored")
    public static let xmlMismatchedTag = IssueCode.custom("xml_mismatched_tag")
    public static let xmlNoRoot = IssueCode.custom("xml_no_root")
    public static let xmlRawLtInAttribute = IssueCode.custom("xml_raw_lt_in_attribute")
    public static let xmlRecursiveEntity = IssueCode.custom("xml_recursive_entity")
    public static let xmlRootMismatch = IssueCode.custom("xml_root_mismatch")
    public static let xmlUnclosedElement = IssueCode.custom("xml_unclosed_element")
    public static let xmlUndeclaredEntity = IssueCode.custom("xml_undeclared_entity")
    public static let xmlUnquotedAttribute = IssueCode.custom("xml_unquoted_attribute")
    public static let xmlUnterminatedAttribute = IssueCode.custom("xml_unterminated_attribute")
    public static let xmlUnterminatedCdata = IssueCode.custom("xml_unterminated_cdata")
    public static let xmlUnterminatedComment = IssueCode.custom("xml_unterminated_comment")
    public static let xmlUnterminatedDoctype = IssueCode.custom("xml_unterminated_doctype")
    public static let xmlUnterminatedEntity = IssueCode.custom("xml_unterminated_entity")
    public static let xmlUnterminatedPi = IssueCode.custom("xml_unterminated_pi")
    public static let xmlUnterminatedTag = IssueCode.custom("xml_unterminated_tag")
}
