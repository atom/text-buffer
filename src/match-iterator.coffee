class Forwards
  constructor: (@text, @regex, @startIndex, @endIndex) ->
    @regex.lastIndex = @startIndex

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

    if match
      {value: match, done: false}
    else
      {value: null, done: true}

class Backwards
  constructor: (@text, @regex, @startIndex, endIndex, @chunkSize) ->
    @bufferedMatches = []
    @chunkStartIndex = @chunkEndIndex = endIndex
    @lastMatchIndex = Infinity

  scanNextChunk: ->
    return false if @chunkStartIndex is @startIndex

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
    true

  next: ->
    while @bufferedMatches.length is 0
      break unless @scanNextChunk()
    if match = @bufferedMatches.pop()
      {value: match, done: false}
    else
      {value: null, done: true}

module.exports = {Forwards, Backwards}
