_ = require 'underscore-plus'
Point = require './point'
Range = require './range'

addContextLinesToCallbackArgument = (argument, options) ->
  argument.leadingContextLines = []
  row = Math.max(0, argument.range.start.row - (options.leadingContextLineCount or 0))
  while row < argument.range.start.row
    argument.leadingContextLines.push(argument.buffer.lineForRow(row))
    row += 1

  argument.trailingContextLines = []
  for i in [0...(options.trailingContextLineCount or 0)]
    row = argument.range.start.row + i + 1
    break if row >= argument.buffer.getLineCount()
    argument.trailingContextLines.push(argument.buffer.lineForRow(row))

class SingleLineSearchCallbackArgument
  lineTextOffset: 0

  Object.defineProperty this.prototype, 'range',
    get: ->
      @computedRange ?= Range(
        Point(@row, @lineOffset + @match.index),
        Point(@row, @lineOffset + @match.index + @matchText.length)
      )

    set: (@computedRange) ->

  Object.defineProperty this.prototype, 'lineText',
    get: -> @buffer.lineForRow(@row)

  constructor: (@buffer, @row, @match, @lineOffset, options={}) ->
    @stopped = false
    @matchText = @match[0]
    addContextLinesToCallbackArgument(this, options)

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: => @stopped = true

class ForwardsSingleLine
  constructor: (@buffer, @regex, @range, @options={}) ->

  iterate: (callback, global) ->
    row = @range.start.row
    line = @buffer.lineForRow(row)
    lineOffset = 0
    @regex.lastIndex = @range.start.column

    while row < @range.end.row
      if match = @regex.exec(line)
        argument = new SingleLineSearchCallbackArgument(@buffer, row, match, lineOffset, @options)
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

    line = line.slice(0, @range.end.column - lineOffset)
    while match = @regex.exec(line)
      break if line.length isnt 0 and match.index is @range.end.column
      argument = new SingleLineSearchCallbackArgument(@buffer, row, match, lineOffset, @options)
      callback(argument)
      return if argument.stopped or not global
      if argument.replacementText?
        lineOffset += argument.replacementText.length - argument.matchText.length
      if match[0].length is 0
        @regex.lastIndex++
    return

class BackwardsSingleLine
  constructor: (@buffer, @regex, @range, @options={}) ->

  iterate: (callback, global) ->
    row = @range.end.row
    endColumn = @range.end.column
    line = @buffer.lineForRow(row).slice(0, @range.end.column)
    bufferedMatches = []
    while row > @range.start.row
      if match = @regex.exec(line)
        if row < @range.end.row or match.index < endColumn or (match.index is endColumn and endColumn is 0)
          bufferedMatches.push(match)
        if match[0].length is 0
          @regex.lastIndex++
      else
        while match = bufferedMatches.pop()
          argument = new SingleLineSearchCallbackArgument(@buffer, row, match, 0, @options)
          callback(argument)
          return if argument.stopped or not global
        row--
        line = @buffer.lineForRow(row)
        @regex.lastIndex = 0

    @regex.lastIndex = @range.start.column
    while match = @regex.exec(line)
      break if row is @range.end.row and (match.index > endColumn or match.index is endColumn and endColumn > 0)
      bufferedMatches.push(match)
      if match[0].length is 0
        @regex.lastIndex++

    while match = bufferedMatches.pop()
      argument = new SingleLineSearchCallbackArgument(@buffer, row, match, 0, @options)
      callback(argument)
      return if argument.stopped or not global
    return

class MultiLineSearchCallbackArgument
  lineTextOffset: 0

  Object.defineProperty this.prototype, 'range',
    get: ->
      return @computedRange if @computedRange?

      matchStartIndex = @match.index
      matchEndIndex = matchStartIndex + @matchText.length

      startPosition = @buffer.positionForCharacterIndex(matchStartIndex + @lengthDelta)
      endPosition = @buffer.positionForCharacterIndex(matchEndIndex + @lengthDelta)

      @computedRange = new Range(startPosition, endPosition)

    set: (range) ->
      @computedRange = range

  Object.defineProperty this.prototype, 'lineText',
    get: -> @buffer.lineForRow(@range.start.row)

  constructor: (@buffer, @match, @lengthDelta, options={}) ->
    @stopped = false
    @replacementText = null
    @matchText = @match[0]
    addContextLinesToCallbackArgument(this, options)

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: =>
    @stopped = true

class ForwardsMultiLine
  constructor: (@buffer, @regex, range, @options={}) ->
    @startIndex = @buffer.characterIndexForPosition(range.start)
    @endIndex = @buffer.characterIndexForPosition(range.end)
    @rangeEndColumn = range.end.column
    @text = @buffer.getText()
    @regex.lastIndex = @startIndex

  iterate: (callback, global) ->
    lengthDelta = 0
    while match = @next()
      argument = new MultiLineSearchCallbackArgument(@buffer, match, lengthDelta, @options)
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
        match = null
        if matchStartIndex < @endIndex or matchStartIndex is @endIndex and @rangeEndColumn is 0
          @regex.lastIndex = 0
          if submatch = @regex.exec(@text[matchStartIndex...@endIndex])
            submatch.index = matchStartIndex
            match = submatch
        @regex.lastIndex = Infinity
      else
        return null if matchStartIndex is @endIndex and @rangeEndColumn > 0
        matchEndIndex++ if matchLength is 0
        @regex.lastIndex = matchEndIndex
      match

class BackwardsMultiLine
  constructor: (@buffer, @regex, range, @chunkSize, @options={}) ->
    @text = @buffer.getText()
    @startIndex = @buffer.characterIndexForPosition(range.start)
    @endIndex = @buffer.characterIndexForPosition(range.end)
    @rangeEndColumn = range.end.column
    @chunkStartIndex = @chunkEndIndex = @endIndex
    @bufferedMatches = []
    @lastMatchIndex = Infinity
    @didInitialScan = false

  iterate: (callback, global) ->
    while match = @next()
      argument = new MultiLineSearchCallbackArgument(@buffer, match, 0, @options)
      callback(argument)
      break unless global and not argument.stopped
    return

  next: ->
    while @bufferedMatches.length is 0 and (not @didInitialScan or @chunkStartIndex > @startIndex)
      @scanNextChunk()
    @bufferedMatches.pop()

  scanNextChunk: ->
    # If results were found in the last chunk, then scan to the beginning
    # of the previous result. Otherwise, continue to scan to the same position
    # as before.
    @chunkEndIndex = Math.min(@chunkEndIndex, @lastMatchIndex)
    @chunkStartIndex = Math.max(@startIndex, @chunkStartIndex - @chunkSize)
    @didInitialScan = true

    firstResultIndex = null
    @regex.lastIndex = @chunkStartIndex
    while match = @regex.exec(@text)
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      # If the match occurs at the beginning of the chunk, expand the chunk
      # in case the match could have started earlier.
      break if matchStartIndex is @chunkStartIndex and @chunkStartIndex > @startIndex
      break if matchStartIndex > @chunkEndIndex or (matchStartIndex is @endIndex and @rangeEndColumn > 0)

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
    return

module.exports = {
  ForwardsMultiLine,
  BackwardsMultiLine,
  ForwardsSingleLine,
  BackwardsSingleLine
}
