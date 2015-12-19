Patch = require 'atom-patch'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
TokenIterator = require './token-iterator'
{traversal, clipNegativePoint} = require './point-helpers'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, patchSeed}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @markerLayersById = {}
    @buffer.onDidChange(@bufferDidChange.bind(this))
    @computeTransformation(0, @buffer.getLineCount())
    @emitter = new Emitter

  addMarkerLayer: (options) ->
    markerLayer = new DisplayMarkerLayer(this, @buffer.addMarkerLayer(options))
    @markerLayersById[markerLayer.id] = markerLayer

  getMarkerLayer: (id) ->
    @markerLayersById[id] ?= new DisplayMarkerLayer(this, @buffer.getMarkerLayer(id))

  onDidChangeTextSync: (callback) ->
    @emitter.on 'did-change-text-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = change
    startRow = oldRange.start.row
    oldEndRow = oldRange.end.row + 1
    newEndRow = newRange.end.row + 1
    {start, replacedExtent} = @patch.spliceInput(Point(startRow, 0), Point(oldEndRow - startRow, 0), Point(newEndRow - startRow, 0))
    newOutputEnd = @computeTransformation(startRow, newEndRow)
    replacementExtent = traversal(newOutputEnd, start)
    @emitter.emit 'did-change-text-sync', {start, replacedExtent, replacementExtent}

  computeTransformation: (startBufferRow, endBufferRow) ->
    {row: screenRow, column: screenColumn} = @translateBufferPosition(Point(startBufferRow, 0))
    for bufferRow in [startBufferRow...endBufferRow] by 1
      line = @buffer.lineForRow(bufferRow)
      for character, bufferColumn in line
        if character is '\t'
          tabText = ''
          tabText += ' ' for i in [0...@tabLength - (screenColumn % @tabLength)] by 1
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          screenColumn += tabText.length
        else
          screenColumn++
      screenRow++
      screenColumn = 0
    Point(screenRow, screenColumn)

  buildTokenIterator: ->
    new TokenIterator(@buffer, @patch.buildIterator())

  getText: ->
    text = ''

    {iterator} = @patch
    iterator.rewind()

    loop
      if iterator.inChange()
        text += iterator.getReplacementText()
      else
        text += @buffer.getTextInRange(Range(iterator.getInputStart(), iterator.getInputEnd()))
      break unless iterator.moveToSuccessor()

    text

  translateBufferPosition: (bufferPosition, options) ->
    bufferPosition = Point.fromObject(bufferPosition)
    bufferPosition = clipNegativePoint(bufferPosition)

    @patchIterator.seekToInputPosition(bufferPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        screenPosition = @patchIterator.getOutputEnd()
      else
        screenPosition = @patchIterator.getOutputStart()
    else
      screenPosition = @patchIterator.translateInputPosition(@buffer.clipPosition(bufferPosition, options))

    Point.fromObject(screenPosition)

  translateBufferRange: (bufferRange, options) ->
    bufferRange = Range.fromObject(bufferRange)
    start = @translateBufferPosition(bufferRange.start, options)
    end = @translateBufferPosition(bufferRange.end, options)
    Range(start, end)

  translateScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        bufferPosition = @patchIterator.getInputEnd()
      else
        bufferPosition = @patchIterator.getInputStart()
    else
      bufferPosition = @buffer.clipPosition(@patchIterator.translateOutputPosition(screenPosition), options)

    Point.fromObject(bufferPosition)

  translateScreenRange: (screenRange, options) ->
    screenRange = Range.fromObject(screenRange)
    start = @translateScreenPosition(screenRange.start, options)
    end = @translateScreenPosition(screenRange.end, options)
    Range(start, end)

  clipScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        clippedScreenPosition = @patchIterator.getOutputEnd()
      else
        clippedScreenPosition =  @patchIterator.getOutputStart()
    else
      bufferPosition = @patchIterator.translateOutputPosition(screenPosition)
      clippedBufferPosition = @buffer.clipPosition(bufferPosition, options)
      clippedScreenPosition =  @patchIterator.translateInputPosition(clippedBufferPosition)

    Point.fromObject(clippedScreenPosition)
