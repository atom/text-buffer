module.exports = (charCode1, charCode2) ->
  isSurrogatePair(charCode1, charCode2) or
  isVariationSequence(charCode1, charCode2) or
  isCombinedCharacter(charCode1, charCode2)

# Are the given character codes a high/low surrogate pair?
#
# * `charCodeA` The first character code {Number}.
# * `charCode2` The second character code {Number}.
#
# Return a {Boolean}.
isSurrogatePair = (charCodeA, charCodeB) ->
  isHighSurrogate(charCodeA) and isLowSurrogate(charCodeB)

# Are the given character codes a variation sequence?
#
# * `charCodeA` The first character code {Number}.
# * `charCode2` The second character code {Number}.
#
# Return a {Boolean}.
isVariationSequence = (charCodeA, charCodeB) ->
  not isVariationSelector(charCodeA) and isVariationSelector(charCodeB)

# Are the given character codes a combined character pair?
#
# * `charCodeA` The first character code {Number}.
# * `charCode2` The second character code {Number}.
#
# Return a {Boolean}.
isCombinedCharacter = (charCodeA, charCodeB) ->
  not isCombiningCharacter(charCodeA) and isCombiningCharacter(charCodeB)

isHighSurrogate = (charCode) ->
  0xD800 <= charCode <= 0xDBFF

isLowSurrogate = (charCode) ->
  0xDC00 <= charCode <= 0xDFFF

isVariationSelector = (charCode) ->
  0xFE00 <= charCode <= 0xFE0F

isCombiningCharacter = (charCode) ->
  0x0300 <= charCode <= 0x036F or
  0x1AB0 <= charCode <= 0x1AFF or
  0x1DC0 <= charCode <= 0x1DFF or
  0x20D0 <= charCode <= 0x20FF or
  0xFE20 <= charCode <= 0xFE2F
