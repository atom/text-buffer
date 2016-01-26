Point = require './point'
Range = require './range'
{traverse, traversal, compare: comparePoints, isEqual: isEqualPoint, characterIndexForPoint} = require './point-helpers'
EMPTY_ARRAY = Object.freeze([])
EmptyDecorationIterator = require './empty-decoration-iterator'

module.exports =
class TokenIterator
  constructor: (@buffer, @patchIterator, @decorationIterator=new EmptyDecorationIterator) ->
    @reset()

  getStartBufferPosition: -> Point.fromObject(@startBufferPosition)

  getStartScreenPosition: -> Point.fromObject(@startScreenPosition)

  getEndBufferPosition: -> Point.fromObject(@endBufferPosition)

  getEndScreenPosition: -> Point.fromObject(@endScreenPosition)

  getText: -> @text

  isFold: ->
    @patchIterator.inChange() and @patchIterator.getMetadata()?.fold

  reset: ->
    @patchIterator.reset()
    @startBufferPosition = null
    @startScreenPosition = null
    @endBufferPosition = null
    @endScreenPosition = null
    @text = null
    @openTags = EMPTY_ARRAY
    @closeTags = EMPTY_ARRAY
    @containingTags = null
    @tagsToReopenAfterFold = null

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
    @containingTags = []
    @closeTags = EMPTY_ARRAY
    @openTags = @decorationIterator.seek(@startBufferPosition)

    if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
      for tag in @decorationIterator.getCloseTags()
        @openTags.splice(@openTags.lastIndexOf(tag), 1)
      @openTags.push(@decorationIterator.getOpenTags()...)

    @assignEndPositionsAndText()

  moveToSuccessor: ->
    for tag in @closeTags
      index = @containingTags.lastIndexOf(tag)
      if index is -1
        throw new Error("Close tag not found in containing tags stack.")
      @containingTags.splice(index, 1)
    @containingTags.push(@openTags...)

    @startScreenPosition = @endScreenPosition
    @startBufferPosition = @endBufferPosition
    @closeTags = EMPTY_ARRAY
    @openTags = EMPTY_ARRAY

    atLineEnd = true
    if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
      atLineEnd = false
      @openTags = []
      @closeTags = []

      closeTags = @decorationIterator.getCloseTags()
      closeTagsToProcess = new Set(closeTags)
      containingTagsIndex = @containingTags.length - 1

      for closeTag in closeTags when closeTagsToProcess.has(closeTag)
        while mostRecentOpenTag = @containingTags[containingTagsIndex--]
          break if mostRecentOpenTag is closeTag

          @closeTags.push(mostRecentOpenTag)
          if closeTagsToProcess.has(mostRecentOpenTag)
            closeTagsToProcess.delete(mostRecentOpenTag)
          else
            @openTags.unshift(mostRecentOpenTag)

        @closeTags.push(closeTag)

      @openTags.push(@decorationIterator.getOpenTags()...)

    if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
      atLineEnd = false
      @patchIterator.moveToSuccessor()

    return false unless @closeTags.length > 0 or @openTags.length > 0 or comparePoints(@startBufferPosition, @buffer.getEndPosition()) < 0

    if atLineEnd
      if @containingTags.length is 0 or @tagsToReopenAfterNewline?
        @startScreenPosition = Point(@startScreenPosition.row + 1, 0)
        @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
        @closeTags = EMPTY_ARRAY
        @openTags = @tagsToReopenAfterNewline ? []
        @tagsToReopenAfterNewline = null

        if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
          for tag in @decorationIterator.getCloseTags()
            @openTags.splice(@openTags.lastIndexOf(tag), 1)
          @openTags.push(@decorationIterator.getOpenTags()...)

        if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
          @patchIterator.moveToSuccessor()
      else
        @tagsToReopenAfterNewline = @containingTags.slice()
        @closeTags = @containingTags.slice().reverse()
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
    if @patchIterator.getOutputEnd().row is @startScreenPosition.row
      @endScreenPosition = @patchIterator.getOutputEnd()
      @endBufferPosition = @patchIterator.getInputEnd()
      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getNewText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        @text = @patchIterator.getNewText().substring(characterIndexInChangeText)
      else
        @text = @buffer.getTextInRange(Range(@startBufferPosition, @endBufferPosition))
    else
      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getNewText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        nextNewlineIndex = @patchIterator.getNewText().indexOf('\n', characterIndexInChangeText)
        @text = @patchIterator.getNewText().substring(characterIndexInChangeText, nextNewlineIndex)
        @endScreenPosition = traverse(@startScreenPosition, Point(0, @text.length))
        @endBufferPosition = @patchIterator.translateOutputPosition(@endScreenPosition)
      else
        @text = @buffer.lineForRow(@startBufferPosition.row).substring(@startBufferPosition.column)
        @endBufferPosition = traverse(@startBufferPosition, Point(0, @text.length))
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)

    if @isFold()
      @closeTags = @containingTags.slice().reverse()
      @openTags = EMPTY_ARRAY
      @tagsToReopenAfterFold = @decorationIterator.seek(@endBufferPosition)
    else
      decorationIteratorPosition = @decorationIterator.getPosition()

      comparison = comparePoints(decorationIteratorPosition, @startBufferPosition)
      if comparison < 0
        bufferRow = decorationIteratorPosition.row
        throw new Error("""
          Invalid text decoration iterator position: #{decorationIteratorPosition}.
          Buffer row #{bufferRow} has length #{@buffer.lineLengthForRow(bufferRow)}.
        """)
      else if comparison is 0
        @decorationIterator.moveToSuccessor()
        decorationIteratorPosition = @decorationIterator.getPosition()

      if comparePoints(decorationIteratorPosition, @endBufferPosition) < 0
        @endBufferPosition = decorationIteratorPosition
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
        @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)
