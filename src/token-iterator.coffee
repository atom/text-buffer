Point = require './point'
Range = require './range'
{traverse, traversal, compare, characterIndexForPoint} = require './point-helpers'

module.exports =
class TokenIterator
  constructor: (@buffer, @patchIterator) ->
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

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
    @assignEndPositionsAndText()

  moveToSuccessor: ->
    if compare(@endScreenPosition, @patchIterator.getOutputEnd()) < 0
      @startScreenPosition = traverse(@endScreenPosition, Point(1, 0))
      @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
      return false if compare(@startBufferPosition, @buffer.getEndPosition()) > 0
    else
      @patchIterator.moveToSuccessor()
      @startScreenPosition = @patchIterator.getOutputStart()
      @startBufferPosition = @patchIterator.getInputStart()
    @assignEndPositionsAndText()

    true

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
        nextNewlineIndex = @patchIterator.getReplacementText().indexOf('\n', @characterIndexInChangeText)
        @text = @patchIterator.getReplacementText().substring(@characterIndexInChangeText, nextNewlineIndex)
        @endScreenPosition = traverse(@startScreenPosition, Point(0, @text.length))
        @endBufferPosition = @patchIterator.translateOutputPosition(@endScreenPosition)
      else
        @text = @buffer.lineForRow(@startBufferPosition.row).substring(@startBufferPosition.column)
        @endBufferPosition = traverse(@startBufferPosition, Point(0, @text.length))
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
