Point = require './point'
Range = require './range'
{traverse, traversal, compare: comparePoints, isEqual: isEqualPoint, isZero: isZeroPoint, characterIndexForPoint} = require './point-helpers'
EMPTY_ARRAY = Object.freeze([])
EmptyDecorationLayer = require './empty-decoration-layer'

module.exports =
class TokenIterator
  constructor: (@displayLayer, @buffer, @spatialTokenIterator, @decorationIterator) ->
    @decorationIterator ?= new EmptyDecorationLayer().buildIterator()
    @reset()

  getStartBufferPosition: -> Point.fromObject(@startBufferPosition)

  getStartScreenPosition: -> Point.fromObject(@startScreenPosition)

  getEndBufferPosition: -> Point.fromObject(@endBufferPosition)

  getEndScreenPosition: -> Point.fromObject(@endScreenPosition)

  getText: -> @text

  isFold: ->
    @spatialTokenIterator.getMetadata()?.fold

  reset: ->
    @startBufferPosition = null
    @startScreenPosition = null
    @endBufferPosition = null
    @endScreenPosition = null
    @text = null
    @openTags = EMPTY_ARRAY
    @closeTags = EMPTY_ARRAY
    @containingTags = null
    @tagsToReopenAfterFold = null
    @baseTokenText = null

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @spatialTokenIterator.seekToScreenPosition(@startScreenPosition)
    @startBufferPosition = @spatialTokenIterator.getBufferStart()
    @containingTags = []
    @closeTags = EMPTY_ARRAY
    @openTags = @decorationIterator.seek(@startBufferPosition) ? []

    if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
      for tag in @decorationIterator.getCloseTags()
        @openTags.splice(@openTags.lastIndexOf(tag), 1)
      @openTags.push(@decorationIterator.getOpenTags()...)
      @decorationIterator.moveToSuccessor()

    if textDecoration = @getSpatialTokenTextDecoration()
      @openTags.push(textDecoration)

    @assignEndPositionsAndText()

  debugCount: 0
  targetDebugCount: Infinity

  moveToSuccessor: ->
    @debugCount++
    debugger if @debugCount >= @targetDebugCount

    for tag in @closeTags
      index = @containingTags.lastIndexOf(tag)
      if index is -1
        debugger
        throw new Error("Close tag not found in containing tags stack.")
      @containingTags.splice(index, 1)
    @containingTags.push(@openTags...)

    @startScreenPosition = @endScreenPosition
    @startBufferPosition = @endBufferPosition
    @closeTags = EMPTY_ARRAY
    @openTags = EMPTY_ARRAY
    tagsToClose = null
    tagsToOpen = null

    if isEqualPoint(@startScreenPosition, @spatialTokenIterator.getScreenEnd())
      if textDecoration = @getSpatialTokenTextDecoration()
        tagsToClose = [textDecoration]
      @spatialTokenIterator.moveToSuccessor()
      @baseTokenText = null
      if textDecoration = @getSpatialTokenTextDecoration()
        tagsToOpen = [textDecoration]

    if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
      tagsToClose ?= []
      tagsToClose.push(@decorationIterator.getCloseTags()...)
      tagsToOpen = (@decorationIterator.getOpenTags() ? []).concat(tagsToOpen ? [])
      @decorationIterator.moveToSuccessor()

    if tagsToClose?
      @closeTags = []
      @openTags = []

      remainingCloseTagOccurrences = {}
      for tag in tagsToClose
        remainingCloseTagOccurrences[tag] ?= 0
        remainingCloseTagOccurrences[tag]++

      containingTagsIndex = @containingTags.length - 1
      for closeTag in tagsToClose when remainingCloseTagOccurrences[closeTag] > 0
        while mostRecentOpenTag = @containingTags[containingTagsIndex--]
          break if mostRecentOpenTag is closeTag

          @closeTags.push(mostRecentOpenTag)
          if remainingCloseTagOccurrences[mostRecentOpenTag] > 0
            remainingCloseTagOccurrences[mostRecentOpenTag]--
          else
            @openTags.unshift(mostRecentOpenTag)

        @closeTags.push(closeTag)

    if tagsToOpen?
      if @openTags.length > 0
        @openTags.push(tagsToOpen...)
      else
        @openTags = tagsToOpen

    return false unless @closeTags.length > 0 or @openTags.length > 0 or comparePoints(@startBufferPosition, @buffer.getEndPosition()) < 0

    debugger if @debugCount >= @targetDebugCount

    if @spatialTokenIterator.getScreenStart().row > @startScreenPosition.row
      if @containingTags.length is 0 or @tagsToReopenAfterNewline?
        @startScreenPosition = @spatialTokenIterator.getScreenStart()
        @startBufferPosition = @spatialTokenIterator.getBufferStart()
        @closeTags = EMPTY_ARRAY
        @openTags = @tagsToReopenAfterNewline ? []
        @tagsToReopenAfterNewline = null

        if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
          for tag in @decorationIterator.getCloseTags()
            @openTags.splice(@openTags.lastIndexOf(tag), 1)
          @openTags.push(@decorationIterator.getOpenTags()...)
          @decorationIterator.moveToSuccessor()

        if textDecoration = @getSpatialTokenTextDecoration()
          @openTags.push(textDecoration)

      else
        @tagsToReopenAfterNewline = @containingTags.slice()
        for tag in @closeTags
          index = @tagsToReopenAfterNewline.lastIndexOf(tag)
          if index is -1
            throw new Error("Close tag not found in containing tags stack.")
          @tagsToReopenAfterNewline.splice(index, 1)
        @closeTags = @closeTags.concat(@tagsToReopenAfterNewline.slice().reverse())
        @openTags = EMPTY_ARRAY
        @endBufferPosition = @startBufferPosition
        @endScreenPosition = @startScreenPosition
        @text = ''
        return true

    if @tagsToReopenAfterFold?
      for tag in @closeTags
        @tagsToReopenAfterFold.splice(@tagsToReopenAfterFold.lastIndexOf(tag), 1)
      @closeTags = EMPTY_ARRAY
      @openTags = @tagsToReopenAfterFold.concat(@openTags)
      @tagsToReopenAfterFold = null

    @assignEndPositionsAndText()
    true

  getOpenTags: -> @openTags

  getCloseTags: -> @closeTags

  assignEndPositionsAndText: ->
    debugger if @debugCount >= @targetDebugCount

    @endScreenPosition = @spatialTokenIterator.getScreenEnd()
    @endBufferPosition = @spatialTokenIterator.getBufferEnd()
    @text = @getBaseTokenText().substring(@startScreenPosition.column - @spatialTokenIterator.getScreenStart().column)

    if @isFold()
      @closeTags = @containingTags.slice().reverse()
      @openTags = EMPTY_ARRAY
      @tagsToReopenAfterFold = @decorationIterator.seek(@endBufferPosition)
    else
      decorationIteratorPosition = @decorationIterator.getPosition()

      comparison = comparePoints(decorationIteratorPosition, @startBufferPosition)
      if comparison < 0
        console.log '!!!', @debugCount
        # debugger
        bufferRow = decorationIteratorPosition.row
        throw new Error("""
          Invalid text decoration iterator position: #{decorationIteratorPosition}.
          Buffer row #{bufferRow} has length #{@buffer.lineLengthForRow(bufferRow)}.
        """)
      else if comparison is 0
        # @decorationIterator.moveToSuccessor()
        decorationIteratorPosition = @decorationIterator.getPosition()

      if comparePoints(decorationIteratorPosition, @endBufferPosition) < 0
        @endBufferPosition = decorationIteratorPosition
        @endScreenPosition = @spatialTokenIterator.translateBufferPosition(@endBufferPosition)
        @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)

  getSpatialTokenTextDecoration: ->
    if metadata = @spatialTokenIterator.getMetadata()
      decoration = ''
      decoration += 'invisible-character ' if metadata.invisibleCharacter
      decoration += 'hard-tab ' if metadata.hardTab
      decoration += 'leading-whitespace ' if metadata.leadingWhitespace
      decoration += 'trailing-whitespace ' if metadata.trailingWhitespace
      decoration += 'eol ' if metadata.eol
      decoration += 'indent-guide ' if metadata.showIndentGuide and @displayLayer.showIndentGuides
      if decoration.length > 0
        decoration.trim()

  getBaseTokenText: ->
    @baseTokenText ?= @computeBaseTokenText()

  computeBaseTokenText: ->
    {invisibles} = @displayLayer

    if metadata = @spatialTokenIterator.getMetadata()
      tokenLength = @spatialTokenIterator.getScreenExtent()

      if metadata.hardTab
        if invisibles.tab?
          return invisibles.tab + ' '.repeat(tokenLength - 1)
        else
          return ' '.repeat(tokenLength)
      else if (metadata.leadingWhitespace or metadata.trailingWhitespace) and invisibles.space?
        return invisibles.space.repeat(tokenLength)
      else if metadata.eol
        return metadata.eol
      else if metadata.void
        return ' '.repeat(tokenLength)
      else if metadata.fold
        return '⋯'

    bufferStart = @spatialTokenIterator.getBufferStart()
    bufferEnd = @spatialTokenIterator.getBufferEnd()
    return @buffer.lineForRow(bufferStart.row).substring(bufferStart.column, bufferEnd.column)
