Point = require './point'
Range = require './range'

class SearchCallbackArgument
  Object.defineProperty @::, "range",
    get: ->
      return @computedRange if @computedRange?

      matchStartIndex = @match.index
      matchEndIndex = matchStartIndex + @matchText.length

      startPosition = @buffer.positionForCharacterIndex(matchStartIndex + @lengthDelta)
      endPosition = @buffer.positionForCharacterIndex(matchEndIndex + @lengthDelta)

      @computedRange = new Range(startPosition, endPosition)

    set: (range) ->
      @computedRange = range

  constructor: (@buffer, @match, @lengthDelta) ->
    @stopped = false
    @replacementText = null
    @matchText = @match[0]

  getReplacementDelta: ->
    return 0 unless @replacementText?
    @replacementText.length - @matchText.length

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: =>
    @stopped = true

class Forwards
  constructor: (@buffer, @regex, @startIndex, @endIndex) ->
    @text = @buffer.getText()
    @regex.lastIndex = @startIndex

  iterate: (callback, global) ->
    lengthDelta = 0
    while match = @next()
      argument = new SearchCallbackArgument(@buffer, match, lengthDelta)
      callback(argument)
      if argument.replacementText?
        lengthDelta += argument.replacementText.length - argument.matchText.length
      break unless global and not arg.stopped
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

class Backwards
  constructor: (@buffer, @regex, @startIndex, endIndex, @chunkSize) ->
    @text = @buffer.getText()
    @bufferedMatches = []
    @chunkStartIndex = @chunkEndIndex = endIndex
    @lastMatchIndex = Infinity

  iterate: (callback, global) ->
    while match = @next()
      argument = new SearchCallbackArgument(@buffer, match, 0)
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

module.exports = {Forwards, Backwards}
