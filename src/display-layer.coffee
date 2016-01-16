Patch = require 'atom-patch'
LineLengthIndex = require 'line-length-index'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
TokenIterator = require './token-iterator'
{traversal, clipNegativePoint} = pointHelpers = require './point-helpers'
comparePoints = pointHelpers.compare
maxPoint = pointHelpers.max

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, @foldsMarkerLayer, patchSeed}={}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @lineLengthIndex = new LineLengthIndex
    @pendingBufferChangesPatch = null
    @pendingDisplayChangesPatch = null
    @displayMarkerLayersById = {}
    @emitChangeEvent = @emitChangeEvent.bind(this)
    @changeEventIsPending = false
    @textDecorationLayer = null
    @foldsMarkerLayer ?= @buffer.addMarkerLayer()
    @foldIdCounter = 1
    @disposables = @buffer.onDidChange(@bufferDidChange.bind(this))
    {screenLineLengths} = @computeTransformation(0, @buffer.getLineCount())
    @lineLengthIndex.splice(0, 0, screenLineLengths)
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

  setTextDecorationLayer: (layer) ->
    @decorationLayerDisposable?.dispose()
    @textDecorationLayer = layer
    @decorationLayerDisposable = layer.onDidInvalidateRange?(@decorationLayerDidInvalidateRange.bind(this))

  foldBufferRange: (bufferRange) ->
    @processPendingBufferChanges()

    bufferRange = @buffer.clipRange(bufferRange)
    foldId = @foldsMarkerLayer.markRange(bufferRange).id
    if @foldsMarkerLayer.findMarkers(containsRange: bufferRange).length is 1
      {bufferStart, bufferEnd} = @expandBufferRangeToScreenLineStarts(bufferRange)
      foldExtent = traversal(bufferEnd, bufferStart)
      {start, replacedExtent} = @patch.spliceInput(bufferStart, foldExtent, foldExtent)
      {screenNewEnd, screenLineLengths} = @computeTransformation(bufferRange.start.row, bufferRange.end.row + 1)
      @lineLengthIndex.splice(start.row, replacedExtent.row, screenLineLengths)
      replacementExtent = traversal(screenNewEnd, start)
      @recordDisplayChange(start, replacedExtent, replacementExtent)
      @scheduleChangeEvent()

    foldId

  foldsIntersectingBufferRange: (bufferRange) ->
    @foldsMarkerLayer.findMarkers(intersectsRange: bufferRange).map ({id}) -> id

  destroyFold: (foldId) ->
    if foldMarker = @foldsMarkerLayer.getMarker(foldId)
      @destroyFoldMarkers([foldMarker])

  destroyFoldsIntersectingBufferRange: (bufferRange) ->
    bufferRange = @buffer.clipRange(bufferRange)
    @destroyFoldMarkers(@foldsMarkerLayer.findMarkers(intersectsRange: bufferRange))

  destroyAllFolds: ->
    @destroyFoldMarkers(@foldsMarkerLayer.getMarkers())

  destroyFoldMarkers: (foldMarkers) ->
    if foldMarkers.length > 0
      @processPendingBufferChanges()
      combinedRangeStart = combinedRangeEnd = foldMarkers[0].getStartPosition()
      for foldMarker in foldMarkers
        combinedRangeEnd = maxPoint(combinedRangeEnd, foldMarker.getEndPosition())
        foldMarker.destroy()
      {bufferStart, bufferEnd} = @expandBufferRangeToScreenLineStarts(Range(combinedRangeStart, combinedRangeEnd))
      foldExtent = traversal(bufferEnd, bufferStart)
      {start, replacedExtent} = @patch.spliceInput(bufferStart, foldExtent, foldExtent)
      {screenNewEnd, screenLineLengths} = @computeTransformation(bufferStart.row, bufferEnd.row)
      @lineLengthIndex.splice(start.row, replacedExtent.row, screenLineLengths)
      replacementExtent = traversal(screenNewEnd, start)
      @recordDisplayChange(start, replacedExtent, replacementExtent)
      @scheduleChangeEvent()

  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  bufferDidChange: (change) ->
    @pendingBufferChangesPatch ?= new Patch
    {oldRange, newRange} = change
    startRow = oldRange.start.row
    oldEndRow = oldRange.end.row
    newEndRow = newRange.end.row
    @pendingBufferChangesPatch.splice(Point(startRow, 0), Point(oldEndRow - startRow, Infinity), Point(newEndRow - startRow, Infinity))
    @scheduleChangeEvent()

  processPendingBufferChanges: ->
    return unless @pendingBufferChangesPatch?

    changes = @pendingBufferChangesPatch.getChanges()
    @pendingBufferChangesPatch = null

    for change in changes
      oldRange = Range.fromPointWithTraversalExtent(change.start, change.replacedExtent)
      newRange = Range.fromPointWithTraversalExtent(change.start, change.replacementExtent)

      {bufferStart, bufferEnd: bufferOldEnd} = @expandBufferRangeToScreenLineStarts(oldRange)
      bufferOldExtent = traversal(bufferOldEnd, bufferStart)
      bufferNewExtent = Point(bufferOldExtent.row + (newRange.end.row - oldRange.end.row), 0)
      {start, replacedExtent} = @patch.spliceInput(bufferStart, bufferOldExtent, bufferNewExtent)

      {screenNewEnd, screenLineLengths} = @computeTransformation(oldRange.start.row, newRange.end.row + 1)
      @lineLengthIndex.splice(start.row, replacedExtent.row, screenLineLengths)

      replacementExtent = traversal(screenNewEnd, start)
      @recordDisplayChange(start, replacedExtent, replacementExtent)

  recordDisplayChange: (start, replacedExtent, replacementExtent) ->
    @pendingDisplayChangesPatch ?= new Patch
    @pendingDisplayChangesPatch.splice(start, replacedExtent, replacementExtent)

  emitChangeEvent: ->
    @processPendingBufferChanges()

    if @textDecorationLayer?
      invalidatedRanges = @textDecorationLayer.getInvalidatedRanges()
      for range in invalidatedRanges
        range = @translateBufferRange(range)
        range.start.column = 0
        range.end.row++
        range.end.column = 0
        extent = range.getExtent()
        @pendingDisplayChangesPatch.splice(range.start, extent, extent)

    changes = @pendingDisplayChangesPatch.getChanges()
    @pendingDisplayChangesPatch = null
    @changeEventIsPending = false
    @emitter.emit 'did-change', changes

  scheduleChangeEvent: ->
    unless @changeEventIsPending
      @changeEventIsPending = true
      process.nextTick(@emitChangeEvent)

  decorationLayerDidInvalidateRange: (bufferRange) ->
    screenRange = @translateBufferRange(bufferRange)
    extent = screenRange.getExtent()
    @recordDisplayChange(screenRange.start, extent, extent)
    @scheduleChangeEvent()

  expandBufferRangeToScreenLineStarts: (range) ->
    # Expand the start of the change to the buffer row that starts
    # the screen row containing the start of the change
    @patchIterator.seekToInputPosition(range.start)
    screenStart = Point(@patchIterator.translateInputPosition(range.start).row, 0)
    @patchIterator.seekToOutputPosition(screenStart)
    bufferStart = @patchIterator.translateOutputPosition(screenStart)

    # Expand the end of the change to the the buffer row that starts
    # the screen row following the screen row containing the end of the change
    @patchIterator.seekToInputPosition(range.end)
    screenEnd = Point(@patchIterator.translateInputPosition(range.end).row + 1, 0)
    @patchIterator.seekToOutputPosition(screenEnd)
    bufferEnd = @patchIterator.translateOutputPosition(screenEnd)

    {bufferStart, bufferEnd}

  computeTransformation: (startBufferRow, endBufferRow) ->
    {startBufferRow, endBufferRow, folds} = @computeFoldsInBufferRowRange(startBufferRow, endBufferRow)
    {row: screenRow, column: screenColumn} = @translateBufferPosition(Point(startBufferRow, 0))

    screenLineLengths = []
    bufferRow = startBufferRow
    bufferColumn = 0
    while bufferRow < endBufferRow
      bufferLine = @buffer.lineForRow(bufferRow)
      bufferLineLength = bufferLine.length
      while bufferColumn <= bufferLineLength
        if foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
          foldStartBufferPosition = Point(bufferRow, bufferColumn)
          foldBufferExtent = traversal(foldEndBufferPosition, foldStartBufferPosition)
          @patch.spliceWithText(Point(screenRow, screenColumn), foldBufferExtent, '⋯')
          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          bufferLine = @buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
          screenColumn += 1
        else if bufferLine[bufferColumn] is '\t'
          tabText = ' '.repeat(@tabLength - (screenColumn % @tabLength))
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          bufferColumn += 1
          screenColumn += tabText.length
        else
          bufferColumn += 1
          screenColumn += 1
      bufferRow += 1
      bufferColumn = 0
      screenLineLengths.push(screenColumn - 1)
      screenRow += 1
      screenColumn = 0

    {screenNewEnd: Point(screenRow, screenColumn), screenLineLengths}

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
          if i < (foldMarkers.length - 1) and comparePoints(foldMarkers[i + 1].getStartPosition(), foldEnd) <= 0
            if comparePoints(foldMarkers[i + 1].getEndPosition(), foldEnd) > 0
              foldEnd = foldMarkers[i + 1].getEndPosition()
            i++
          else
            break

        # Add non-empty folds to the index.
        if comparePoints(foldEnd, foldStart) > 0
          folds[foldStart.row] ?= {}
          folds[foldStart.row][foldStart.column] = foldEnd

        i++

    {folds, startBufferRow, endBufferRow}

  buildTokenIterator: ->
    new TokenIterator(@buffer, @patch.buildIterator(), @textDecorationLayer?.buildIterator())

  getText: ->
    @processPendingBufferChanges()

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
    @processPendingBufferChanges()

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
    @processPendingBufferChanges()

    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward' and comparePoints(screenPosition, @patchIterator.getOutputStart()) > 0
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
    @processPendingBufferChanges()

    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward' and comparePoints(screenPosition, @patchIterator.getOutputStart()) > 0
        clippedScreenPosition = @patchIterator.getOutputEnd()
      else
        clippedScreenPosition =  @patchIterator.getOutputStart()
    else
      bufferPosition = @patchIterator.translateOutputPosition(screenPosition)
      clippedBufferPosition = @buffer.clipPosition(bufferPosition, options)
      clippedScreenPosition =  @patchIterator.translateInputPosition(clippedBufferPosition)

    Point.fromObject(clippedScreenPosition)

  getScreenLineCount: ->
    @clipScreenPosition(Point(Infinity, Infinity)).row + 1

  getRightmostScreenPosition: ->
    @processPendingBufferChanges()
    @lineLengthIndex.getPointWithMaxLineLength()

  lineLengthForScreenRow: (screenRow) ->
    @processPendingBufferChanges()
    @lineLengthIndex.lineLengthForRow(screenRow)
