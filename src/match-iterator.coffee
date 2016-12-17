Point = require './point'
Range = require './range'

class SingleLineSearchCallbackArgument
  lineTextOffset: 0

  Object.defineProperty @::, 'range',
    get: ->
      @computedRange ?= Range(
        Point(@row, @lineOffset + @match.index),
        Point(@row, @lineOffset + @match.index + @matchText.length)
      )

    set: (@computedRange) ->

  Object.defineProperty @::, 'lineText',
    get: -> @buffer.lineForRow(@row)

  constructor: (@buffer, @row, @match, @lineOffset) ->
    @stopped = false
    @matchText = @match[0]

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: => @stopped = true

class ForwardsSingleLine
  constructor: (@buffer, @regex, @range) ->

  iterate: (callback, global) ->
    row = @range.start.row
    lineOffset = @range.start.column
    line = @buffer.lineForRow(row).slice(lineOffset)

    while row < @range.end.row
      if match = @regex.exec(line)
        argument = new SingleLineSearchCallbackArgument(@buffer, row, match, lineOffset)
        callback(argument)
        return if argument.stopped or not global
        if argument.replacementText?
          lineOffset += argument.replacementText.length - argument.matchText.length
        if match[0].length is 0
          @regex.lastIndex++
      else
        row++
        lineOffset = 0
        line = @buffer.lineForRow(row)
        @regex.lastIndex = 0

    line = line.slice(0, @range.end.column - @buffer.lineLengthForRow(row))
    while match = @regex.exec(line)
      argument = new SingleLineSearchCallbackArgument(@buffer, row, match, lineOffset)
      callback(argument)
      return if argument.stopped or not global
      if argument.replacementText?
        lineOffset += argument.replacementText.length - argument.matchText.length
      if match[0].length is 0
        @regex.lastIndex++

class BackwardsSingleLine
  constructor: (@buffer, @regex, @range) ->

  iterate: (callback, global) ->
    row = @range.end.row
    line = @buffer.lineForRow(row).slice(0, @range.end.column - @buffer.lineLengthForRow(row))
    bufferedMatches = []
    while row > @range.start.row
      if match = @regex.exec(line)
        bufferedMatches.push(match)
        if match[0].length is 0
          @regex.lastIndex++
      else
        while match = bufferedMatches.pop()
          argument = new SingleLineSearchCallbackArgument(@buffer, row, match, 0)
          callback(argument)
          return if argument.stopped or not global
        row--
        line = @buffer.lineForRow(row)
        @regex.lastIndex = 0

    line = line.slice(@range.start.column)
    while match = @regex.exec(line)
      bufferedMatches.push(match)
      if match[0].length is 0
        @regex.lastIndex++

    while match = bufferedMatches.pop()
      argument = new SingleLineSearchCallbackArgument(@buffer, row, match, @range.start.column)
      callback(argument)
      return if argument.stopped or not global

class MultiLineSearchCallbackArgument
  lineTextOffset: 0

  Object.defineProperty @::, 'range',
    get: ->
      return @computedRange if @computedRange?

      matchStartIndex = @match.index
      matchEndIndex = matchStartIndex + @matchText.length

      startPosition = @buffer.positionForCharacterIndex(matchStartIndex + @lengthDelta)
      endPosition = @buffer.positionForCharacterIndex(matchEndIndex + @lengthDelta)

      @computedRange = new Range(startPosition, endPosition)

    set: (range) ->
      @computedRange = range

  Object.defineProperty @::, 'lineText',
    get: -> @buffer.lineForRow(@range.start.row)

  constructor: (@buffer, @match, @lengthDelta) ->
    @stopped = false
    @replacementText = null
    @matchText = @match[0]

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: =>
    @stopped = true

class ForwardsMultiLine
  constructor: (@buffer, @regex, range) ->
    @startIndex = @buffer.characterIndexForPosition(range.start)
    @endIndex = @buffer.characterIndexForPosition(range.end)
    @text = @buffer.getText()
    @regex.lastIndex = @startIndex

  iterate: (callback, global) ->
    lengthDelta = 0
    while match = @next()
      argument = new MultiLineSearchCallbackArgument(@buffer, match, lengthDelta)
      callback(argument)
      if argument.replacementText?
        lengthDelta += argument.replacementText.length - argument.matchText.length
      break unless global and not argument.stopped
    return

  next: ->
    if match = @regex.exec(@text)
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength
      if matchEndIndex > @endIndex
        @regex.lastIndex = 0
        if matchStartIndex < @endIndex and submatch = @regex.exec(@text[matchStartIndex...@endIndex])
          submatch.index = matchStartIndex
          match = submatch
        else
          match = null
        @regex.lastIndex = Infinity
      else
        matchEndIndex++ if matchLength is 0
        @regex.lastIndex = matchEndIndex
      match

class BackwardsMultiLine
  constructor: (@buffer, @regex, range, @chunkSize) ->
    @text = @buffer.getText()
    @startIndex = @buffer.characterIndexForPosition(range.start)
    @chunkStartIndex = @chunkEndIndex = @buffer.characterIndexForPosition(range.end)
    @bufferedMatches = []
    @lastMatchIndex = Infinity

  iterate: (callback, global) ->
    while match = @next()
      argument = new MultiLineSearchCallbackArgument(@buffer, match, 0)
      callback(argument)
      break unless global and not argument.stopped
    return

  scanNextChunk: ->
    # If results were found in the last chunk, then scan to the beginning
    # of the previous result. Otherwise, continue to scan to the same position
    # as before.
    @chunkEndIndex = Math.min(@chunkEndIndex, @lastMatchIndex)
    @chunkStartIndex = Math.max(@startIndex, @chunkStartIndex - @chunkSize)

    firstResultIndex = null
    @regex.lastIndex = @chunkStartIndex
    while match = @regex.exec(@text)
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      # If the match occurs at the beginning of the chunk, expand the chunk
      # in case the match could have started earlier.
      break if matchStartIndex == @chunkStartIndex > @startIndex
      break if matchStartIndex >= @chunkEndIndex

      if matchEndIndex > @chunkEndIndex
        @regex.lastIndex = 0
        if submatch = @regex.exec(@text[matchStartIndex...@chunkEndIndex])
          submatch.index = matchStartIndex
          firstResultIndex ?= matchStartIndex
          @bufferedMatches.push(submatch)
        break
      else
        firstResultIndex ?= matchStartIndex
        @bufferedMatches.push(match)
        matchEndIndex++ if matchLength is 0
        @regex.lastIndex = matchEndIndex

    @lastMatchIndex = firstResultIndex if firstResultIndex

  next: ->
    until @chunkStartIndex is @startIndex or @bufferedMatches.length > 0
      @scanNextChunk()
    @bufferedMatches.pop()

module.exports = {
  ForwardsMultiLine,
  BackwardsMultiLine,
  ForwardsSingleLine,
  BackwardsSingleLine
}
