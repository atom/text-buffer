Patch = require 'atom-patch'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
TokenIterator = require './token-iterator'
{traversal, clipNegativePoint} = require './point-helpers'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, patchSeed}={}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @displayMarkerLayersById = {}
    @foldsMarkerLayer = @buffer.addMarkerLayer()
    @foldIdCounter = 1
    @buffer.onDidChange(@bufferDidChange.bind(this))
    @computeTransformation(0, @buffer.getLineCount())
    @emitter = new Emitter

  destroy: ->
    @foldsMarkerLayer.destroy()
    for id, displayMarkerLayer of @displayMarkerLayersById
      displayMarkerLayer.destroy()

  addMarkerLayer: (options) ->
    markerLayer = new DisplayMarkerLayer(this, @buffer.addMarkerLayer(options))
    @displayMarkerLayersById[markerLayer.id] = markerLayer

  getMarkerLayer: (id) ->
    @displayMarkerLayersById[id] ?= new DisplayMarkerLayer(this, @buffer.getMarkerLayer(id))

  foldBufferRange: (bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    foldId = @foldsMarkerLayer.markRange(bufferRange).id
    if @foldsMarkerLayer.findMarkers(containsRange: bufferRange).length is 1
      @computeTransformation(bufferRange.start.row, bufferRange.end.row)
    foldId

  destroyFold: (foldId) ->
    foldMarker = @foldsMarkerLayer.getMarker(foldId)
    foldRange = foldMarker.getRange()
    foldMarker.destroy()
    if @foldsMarkerLayer.findMarkers(containsRange: foldRange).length is 0
      foldExtent = foldRange.getExtent()
      @patch.spliceInput(foldRange.start, foldExtent, foldExtent)
      @computeTransformation(foldRange.start.row, foldRange.end.row)

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
    startBufferRow = @translateScreenPosition(@translateBufferPosition(Point(startBufferRow, 0))).row
    folds = @computeFoldsInBufferRowRange(startBufferRow, endBufferRow)
    {row: screenRow, column: screenColumn} = @translateBufferPosition(Point(startBufferRow, 0))

    bufferRow = startBufferRow
    bufferColumn = 0
    while bufferRow < endBufferRow
      line = @buffer.lineForRow(bufferRow)
      lineLength = line.length
      while bufferColumn <= lineLength
        if foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
          foldStartScreenPosition = Point(screenRow, screenColumn)
          foldEndScreenPosition = @translateBufferPosition(foldEndBufferPosition)
          foldScreenExtent = traversal(foldEndScreenPosition, foldStartScreenPosition)
          @patch.spliceWithText(foldStartScreenPosition, foldScreenExtent, '⋯')
          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          line = @buffer.lineForRow(bufferRow)
          lineLength = line.length
          screenColumn += 1
        else if line[bufferColumn] is '\t'
          tabText = ''
          tabText += ' ' for i in [0...@tabLength - (screenColumn % @tabLength)] by 1
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          bufferColumn += 1
          screenColumn += tabText.length
        else
          bufferColumn += 1
          screenColumn += 1
      bufferRow += 1
      bufferColumn = 0
      screenRow += 1
      screenColumn = 0

    Point(screenRow, screenColumn)

  computeFoldsInBufferRowRange: (startBufferRow, endBufferRow) ->
    folds = {}
    foldMarkers = @foldsMarkerLayer.findMarkers(intersectsRowRange: [startBufferRow, endBufferRow], excludeNested: true)
    foldMarkersLength = foldMarkers.length
    i = 0
    while i < foldMarkersLength
      startMarker = endMarker = foldMarkers[i]
      while foldMarkers[i + 1]? && endMarker.getRange().containsPoint(foldMarkers[i + 1].getStartPosition())
        endMarker = foldMarkers[i + 1]
        i++
      start = startMarker.getStartPosition()
      folds[start.row] ?= {}
      folds[start.row][start.column] = endMarker.getEndPosition()
      i++
    folds

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
