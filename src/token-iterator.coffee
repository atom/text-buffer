Point = require './point'
Range = require './range'
{traverse, traversal, compare, characterIndexForPoint} = require './point-helpers'

module.exports =
class TokenIterator
  constructor: (@buffer, @patchIterator, @decorationIterators) ->
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
    @openTags = []
    @closeTags = []
    @decorationIteratorsToAdvance = []
    @advancePatchIterator = false
    @atLineEnd = false

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
    @openTags.length = 0

    containingTags = []
    for decorationIterator in @decorationIterators
      containingTagsForIterator = decorationIterator.seek(@startBufferPosition)
      containingTags.push(containingTagsForIterator...)

    @assignEndPositionsAndText()
    containingTags

  moveToSuccessor: ->
    @openTags.length = 0

    if @atLineEnd
      @startScreenPosition = traverse(@endScreenPosition, Point(1, 0))
      @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
      return false if compare(@startBufferPosition, @buffer.getEndPosition()) > 0
    else
      @startScreenPosition = @endScreenPosition
      @startBufferPosition = @endBufferPosition

    if @advancePatchIterator
      unless @patchIterator.moveToSuccessor()
        return false

    for iterator in @decorationIteratorsToAdvance
      if iterator.moveToSuccessor()
        @openTags.push(iterator.getOpenTags()...)
      else
        @decorationIterators.splice(@decorationIterators.indexOf(iterator), 1)

    @assignEndPositionsAndText()
    true

  getOpenTags: ->
    @openTags

  getCloseTags: ->
    @closeTags

  assignEndPositionsAndText: ->
    if @patchIterator.getOutputEnd().row is @startScreenPosition.row
      @advancePatchIterator = true
      @atLineEnd = false
      @endScreenPosition = @patchIterator.getOutputEnd()
      @endBufferPosition = @patchIterator.getInputEnd()

      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getReplacementText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        @text = @patchIterator.getReplacementText().substring(characterIndexInChangeText)
      else
        @text = @buffer.getTextInRange(Range(@startBufferPosition, @endBufferPosition))
    else
      @advancePatchIterator = false
      @atLineEnd = true
      if @patchIterator.inChange()
        nextNewlineIndex = @patchIterator.getReplacementText().indexOf('\n', @characterIndexInChangeText)
        @text = @patchIterator.getReplacementText().substring(@characterIndexInChangeText, nextNewlineIndex)
        @endScreenPosition = traverse(@startScreenPosition, Point(0, @text.length))
        @endBufferPosition = @patchIterator.translateOutputPosition(@endScreenPosition)
      else
        @text = @buffer.lineForRow(@startBufferPosition.row).substring(@startBufferPosition.column)
        @endBufferPosition = traverse(@startBufferPosition, Point(0, @text.length))
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)

    @decorationIteratorsToAdvance.length = 0
    @closeTags.length = 0
    for decorationIterator in @decorationIterators
      decorationIteratorEndPosition = decorationIterator.getEndPosition()
      comparison = compare(decorationIteratorEndPosition, @endBufferPosition)
      if comparison < 0
        @decorationIteratorsToAdvance.length = 0
        @advancePatchIterator = false
        @closeTags.length = 0
        @atLineEnd = false
        @endBufferPosition = decorationIteratorEndPosition
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
        @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)

      if comparison <= 0
        @decorationIteratorsToAdvance.push(decorationIterator)
        @closeTags.push(decorationIterator.getCloseTags()...)
    return
