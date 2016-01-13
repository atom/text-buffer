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

  isFold: ->
    @patchIterator.inChange() and @text is '⋯'

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
    @tagsToReopen = null

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
    @openTags = EMPTY_ARRAY

    if @decorationIterator?
      @containingTags = @decorationIterator.seek(@startBufferPosition) ? EMPTY_ARRAY

      if isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
        @closeTags = @decorationIterator.getCloseTags()
        @openTags = @decorationIterator.getOpenTags()

    @assignEndPositionsAndText()

    @containingTags

  moveToSuccessor: ->
    for tag in @closeTags
      @containingTags.splice(@containingTags.lastIndexOf(tag), 1)
    @containingTags.push(@openTags...)

    @startScreenPosition = @endScreenPosition
    @startBufferPosition = @endBufferPosition
    @closeTags = EMPTY_ARRAY
    @openTags = EMPTY_ARRAY

    advanceToNextLine = true
    if @decorationIterator? and isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
      advanceToNextLine = false
      @closeTags = @decorationIterator.getCloseTags()
      @openTags = @decorationIterator.getOpenTags()

    if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
      advanceToNextLine = false
      @patchIterator.moveToSuccessor()

    return false unless @closeTags.length > 0 or @openTags.length > 0 or comparePoints(@startBufferPosition, @buffer.getEndPosition()) < 0

    if advanceToNextLine
      @startScreenPosition = Point(@startScreenPosition.row + 1, 0)
      @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)

      if @decorationIterator? and isEqualPoint(@startBufferPosition, @decorationIterator.getPosition())
        @closeTags = @decorationIterator.getCloseTags()
        @openTags = @decorationIterator.getOpenTags()

      if isEqualPoint(@startScreenPosition, @patchIterator.getOutputEnd())
        @patchIterator.moveToSuccessor()

    if @tagsToReopen?
      for tag in @closeTags
        @tagsToReopen.splice(@tagsToReopen.lastIndexOf(tag), 1)
      @closeTags = EMPTY_ARRAY
      @openTags = @tagsToReopen.concat(@openTags)
      @tagsToReopen = null

    @assignEndPositionsAndText()
    true

  getOpenTags: -> @openTags

  getCloseTags: -> @closeTags

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

    if @decorationIterator?
      if @isFold()
        @closeTags = @containingTags.slice()
        @containingTags.length = 0
        @openTags = EMPTY_ARRAY
        @tagsToReopen = @decorationIterator.seek(@getEndBufferPosition())
      else
        decorationIteratorPosition = @decorationIterator.getPosition()

        if isEqualPoint(decorationIteratorPosition, @startBufferPosition)
          @decorationIterator.moveToSuccessor()
          decorationIteratorPosition = @decorationIterator.getPosition()

        if comparePoints(decorationIteratorPosition, @endBufferPosition) < 0
          @endBufferPosition = decorationIteratorPosition
          @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
          @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)
