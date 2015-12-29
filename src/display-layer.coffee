Patch = require 'atom-patch'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
TokenIterator = require './token-iterator'
{traversal, clipNegativePoint, compare} = require './point-helpers'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, @foldsMarkerLayer, patchSeed}={}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @displayMarkerLayersById = {}
    @foldsMarkerLayer ?= @buffer.addMarkerLayer()
    @foldIdCounter = 1
    @disposables = @buffer.onDidChange(@bufferDidChange.bind(this))
    @computeTransformation(0, @buffer.getLineCount())
    @emitter = new Emitter

  destroy: ->
    @disposables.dispose()
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
      @computeTransformation(bufferRange.start.row, bufferRange.end.row + 1)
    foldId

  destroyFold: (foldId) ->
    foldMarker = @foldsMarkerLayer.getMarker(foldId)
    foldRange = foldMarker.getRange()
    foldMarker.destroy()
    if @foldsMarkerLayer.findMarkers(containsRange: foldRange).length is 0
      foldExtent = foldRange.getExtent()
      @patch.spliceInput(foldRange.start, foldExtent, foldExtent)
      @computeTransformation(foldRange.start.row, foldRange.end.row + 1)

  onDidChangeTextSync: (callback) ->
    @emitter.on 'did-change-text-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = change
    {start, replacedExtent} = @patch.spliceInput(
      oldRange.start,
      traversal(oldRange.end, oldRange.start),
      traversal(newRange.end, oldRange.start)
    )
    start = Point(start.row, 0)
    replacedExtent = Point(replacedExtent.row + 1, 0)

    newOutputEnd = @computeTransformation(oldRange.start.row, newRange.end.row + 1)
    replacementExtent = traversal(newOutputEnd, start)
    @emitter.emit 'did-change-text-sync', {start, replacedExtent, replacementExtent}

  computeTransformation: (startBufferRow, endBufferRow) ->
    {startBufferRow, endBufferRow, folds} = @computeFoldsInBufferRowRange(startBufferRow, endBufferRow)
    start = Point(startBufferRow, 0)
    extent = Point(endBufferRow - startBufferRow, 0)
    @patch.spliceInput(start, extent, extent)

    {row: screenRow, column: screenColumn} = @translateBufferPosition(Point(startBufferRow, 0))

    bufferRow = startBufferRow
    bufferColumn = 0
    while bufferRow < endBufferRow
      line = @buffer.lineForRow(bufferRow)
      lineLength = line.length
      while bufferColumn <= lineLength
        if foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
          foldStartBufferPosition = Point(bufferRow, bufferColumn)
          foldBufferExtent = traversal(foldEndBufferPosition, foldStartBufferPosition)
          @patch.spliceWithText(Point(screenRow, screenColumn), foldBufferExtent, '⋯')
          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          line = @buffer.lineForRow(bufferRow)
          lineLength = line.length
          screenColumn += 1
        else if line[bufferColumn] is '\t'
          tabText = ' '.repeat(@tabLength - (screenColumn % @tabLength))
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

  # Given a buffer row range, compute an index of all folds that appear on
  # screen lines containing this range. This may expand the initial buffer range
  # if the start row or end row appear on the same screen line as earlier or
  # later buffer lines due to folds.
  #
  # Returns an object containing the new startBufferRow and endBufferRow, along
  # with a folds object mapping startRow to startColumn to endPosition. This
  # object will be referenced when updating the patch to skip folded regions of
  # the buffer.
  computeFoldsInBufferRowRange: (startBufferRow, endBufferRow) ->
    folds = {}
    foldMarkers = @foldsMarkerLayer.findMarkers(intersectsRowRange: [startBufferRow, endBufferRow - 1])
    if foldMarkers.length > 0
      # If the first fold starts before the initial row range, prepend any
      # fold markers that intersect the first fold's row range.
      loop
        foldsStartBufferRow = foldMarkers[0].getStartPosition().row
        break unless foldsStartBufferRow < startBufferRow
        precedingFoldMarkers = @foldsMarkerLayer.findMarkers(intersectsRowRange: [foldsStartBufferRow, startBufferRow - 1])
        foldMarkers.unshift(precedingFoldMarkers...)
        startBufferRow = foldsStartBufferRow

      # Index fold end positions by their start row and start column.
      i = 0
      while i < foldMarkers.length
        foldStart = foldMarkers[i].getStartPosition()
        foldEnd = foldMarkers[i].getEndPosition()

        # Process subsequent folds that intersect the current fold.
        loop
          # If the current fold ends after the queried row range, perform an
          # additional query for any subsequent folds that intersect the portion
          # of the current fold's row range omitted from previous queries.
          if foldEnd.row >= endBufferRow
            followingFoldMarkers = @foldsMarkerLayer.findMarkers(intersectsRowRange: [endBufferRow, foldEnd.row])
            foldMarkers.push(followingFoldMarkers...)
            endBufferRow = foldEnd.row + 1

          # Skip subsequent fold markers that nest within the current fold, and
          # merge folds that start within the the current fold but end after it.
          if i < (foldMarkers.length - 1) and compare(foldMarkers[i + 1].getStartPosition(), foldEnd) <= 0
            if compare(foldMarkers[i + 1].getEndPosition(), foldEnd) > 0
              foldEnd = foldMarkers[i + 1].getEndPosition()
            i++
          else
            break

        # Add non-empty folds to the index.
        if compare(foldEnd, foldStart) > 0
          folds[foldStart.row] ?= {}
          folds[foldStart.row][foldStart.column] = foldEnd

        i++

    {folds, startBufferRow, endBufferRow}

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
