Point = require './point'
Range = require './range'
{traverse, traversal, compare: comparePoints, isEqual: isEqualPoint, characterIndexForPoint} = require './point-helpers'
EMPTY_ARRAY = Object.freeze([])

module.exports =
class TokenIterator
  constructor: (@buffer, @patchIterator, @decorationIterator) ->
    @reset()

  getStartBufferPosition: -> Point.fromObject(@startBufferPosition)

  getStartScreenPosition: -> Point.fromObject(@startScreenPosition)

  getEndBufferPosition: -> Point.fromObject(@endBufferPosition)

  getEndScreenPosition: -> Point.fromObject(@endScreenPosition)

  getText: -> @text

  reset: ->
    @patchIterator.reset()
    @startBufferPosition = null
    @startScreenPosition = null
    @endBufferPosition = null
    @endScreenPosition = null
    @text = null
    @openTags = null
    @closeTags = null

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
    @openTags = null

    if @decorationIterator?
      containingTags = @decorationIterator.seek(@startBufferPosition)
      if isEqualPoint(@startBufferPosition, @decorationIterator.getStartPosition())
        @openTags = @decorationIterator.getOpenTags()

    @assignEndPositionsAndText()

    containingTags ? EMPTY_ARRAY

  moveToSuccessor: ->
    @startScreenPosition = @endScreenPosition
    @startBufferPosition = @endBufferPosition
    @openTags = null

    advanceToNextLine = true
    if @decorationIterator? and isEqualPoint(@startBufferPosition, @decorationIterator.getEndPosition())
      advanceToNextLine = false
      if @decorationIterator.moveToSuccessor()
        @openTags = @decorationIterator.getOpenTags()
      else
        @decorationIterator = null

    if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
      advanceToNextLine = false
      @patchIterator.moveToSuccessor()

    return false unless @openTags? or comparePoints(@startBufferPosition, @buffer.getEndPosition()) < 0

    if advanceToNextLine
      @startScreenPosition = Point(@startScreenPosition.row + 1, 0)
      @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)

      if (@decorationIterator? and
          isEqualPoint(@startBufferPosition, @decorationIterator.getEndPosition()) and
            @decorationIterator.getCloseTags().length is 0)
        if @decorationIterator.moveToSuccessor()
          @openTags = @decorationIterator.getOpenTags()
        else
          @decorationIterator = null

      if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
        @patchIterator.moveToSuccessor()

    @assignEndPositionsAndText()
    true

  getOpenTags: -> @openTags ? EMPTY_ARRAY

  getCloseTags: -> @closeTags ? EMPTY_ARRAY

  assignEndPositionsAndText: ->
    if @patchIterator.getOutputEnd().row is @startScreenPosition.row
      @endScreenPosition = @patchIterator.getOutputEnd()
      @endBufferPosition = @patchIterator.getInputEnd()
      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getReplacementText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        @text = @patchIterator.getReplacementText().substring(characterIndexInChangeText)
      else
        @text = @buffer.getTextInRange(Range(@startBufferPosition, @endBufferPosition))
    else
      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getReplacementText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        nextNewlineIndex = @patchIterator.getReplacementText().indexOf('\n', characterIndexInChangeText)
        @text = @patchIterator.getReplacementText().substring(characterIndexInChangeText, nextNewlineIndex)
        @endScreenPosition = traverse(@startScreenPosition, Point(0, @text.length))
        @endBufferPosition = @patchIterator.translateOutputPosition(@endScreenPosition)
      else
        @text = @buffer.lineForRow(@startBufferPosition.row).substring(@startBufferPosition.column)
        @endBufferPosition = traverse(@startBufferPosition, Point(0, @text.length))
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)

    @closeTags = null

    if @decorationIterator?
      decorationIteratorEndPosition = @decorationIterator.getEndPosition()
      comparison = comparePoints(decorationIteratorEndPosition, @endBufferPosition)

      if comparison < 0
        @endBufferPosition = decorationIteratorEndPosition
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
        @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)

      if comparison <= 0
        @closeTags = @decorationIterator.getCloseTags()
