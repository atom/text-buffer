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
  constructor: (@buffer, {@tabLength, @foldsMarkerLayer, @invisibles, @showIndentGuides, patchSeed}={}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @lineLengthIndex = new LineLengthIndex
    @displayMarkerLayersById = {}
    @textDecorationLayer = null
    @foldsMarkerLayer ?= @buffer.addMarkerLayer()
    @invisibles ?= {}
    @eolInvisibles = {
      "\r": @invisibles.cr
      "\n": @invisibles.eol
      "\r\n": @invisibles.cr + @invisibles.eol
    }
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
    bufferRange = @buffer.clipRange(bufferRange)
    foldId = @foldsMarkerLayer.markRange(bufferRange).id
    if @foldsMarkerLayer.findMarkers(containsRange: bufferRange).length is 1
      {bufferStart, bufferEnd} = @expandBufferRangeToScreenLineStarts(bufferRange)
      foldExtent = traversal(bufferEnd, bufferStart)
      {start, oldExtent} = @patch.spliceInput(bufferStart, foldExtent, foldExtent)
      {screenNewEnd, screenLineLengths} = @computeTransformation(bufferRange.start.row, bufferRange.end.row + 1)
      @lineLengthIndex.splice(start.row, oldExtent.row, screenLineLengths)
      newExtent = traversal(screenNewEnd, start)
      @emitter.emit 'did-change-sync', [{start, oldExtent, newExtent}]

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
      combinedRangeStart = combinedRangeEnd = foldMarkers[0].getStartPosition()
      for foldMarker in foldMarkers
        combinedRangeEnd = maxPoint(combinedRangeEnd, foldMarker.getEndPosition())
        foldMarker.destroy()
      {bufferStart, bufferEnd} = @expandBufferRangeToScreenLineStarts(Range(combinedRangeStart, combinedRangeEnd))
      foldExtent = traversal(bufferEnd, bufferStart)
      {start, oldExtent} = @patch.spliceInput(bufferStart, foldExtent, foldExtent)
      {screenNewEnd, screenLineLengths} = @computeTransformation(bufferStart.row, bufferEnd.row)
      @lineLengthIndex.splice(start.row, oldExtent.row, screenLineLengths)
      newExtent = traversal(screenNewEnd, start)
      @emitter.emit 'did-change-sync', [{start, oldExtent, newExtent}]

  onDidChangeSync: (callback) ->
    @emitter.on 'did-change-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = change

    {bufferStart, bufferEnd: bufferOldEnd} = @expandBufferRangeToScreenLineStarts(oldRange)
    bufferOldExtent = traversal(bufferOldEnd, bufferStart)
    bufferNewExtent = Point(bufferOldExtent.row + (newRange.end.row - oldRange.end.row), 0)
    {start, oldExtent} = @patch.spliceInput(bufferStart, bufferOldExtent, bufferNewExtent)

    {screenNewEnd, screenLineLengths} = @computeTransformation(oldRange.start.row, newRange.end.row + 1)
    @lineLengthIndex.splice(start.row, oldExtent.row, screenLineLengths)

    newExtent = traversal(screenNewEnd, start)
    combinedChanges = new Patch
    combinedChanges.splice(start, oldExtent, newExtent)

    if @textDecorationLayer?
      invalidatedRanges = @textDecorationLayer.getInvalidatedRanges()
      for range in invalidatedRanges
        range = @translateBufferRange(range)
        range.start.column = 0
        range.end.row++
        range.end.column = 0
        extent = range.getExtent()
        combinedChanges.splice(range.start, extent, extent)

    @emitter.emit 'did-change-sync', combinedChanges.getChanges()

  decorationLayerDidInvalidateRange: (bufferRange) ->
    screenRange = @translateBufferRange(bufferRange)
    extent = screenRange.getExtent()
    @emitter.emit 'did-change-sync', [{
      start: screenRange.start,
      oldExtent: extent,
      newExtent: extent
    }]

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

      trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartColumn(bufferLine)
      trailingWhitespaceStartScreenColumn = Infinity # will be assigned during line traversal
      isBlankLine = trailingWhitespaceStartBufferColumn is 0
      inLeadingWhitespace = not isBlankLine
      leadingWhitespaceStartScreenColumn = 0

      while bufferColumn <= bufferLineLength
        character = bufferLine[bufferColumn]
        foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
        inTrailingWhitespace = bufferColumn >= trailingWhitespaceStartBufferColumn
        trailingWhitespaceStartScreenColumn = screenColumn if bufferColumn is trailingWhitespaceStartBufferColumn

        if inLeadingWhitespace
          atSoftTabBoundary = (screenColumn % @tabLength) is 0 and (screenColumn - leadingWhitespaceStartScreenColumn) is @tabLength
        else if isBlankLine and inTrailingWhitespace
          atSoftTabBoundary = (screenColumn % @tabLength) is 0 and (screenColumn - trailingWhitespaceStartScreenColumn) is @tabLength
        else
          atSoftTabBoundary = false

        if character isnt ' ' or foldEndBufferPosition? or atSoftTabBoundary
          if inLeadingWhitespace and bufferColumn < bufferLineLength
            inLeadingWhitespace = false unless character is ' ' or character is '\t'
            if screenColumn > leadingWhitespaceStartScreenColumn
              spaceCount = screenColumn - leadingWhitespaceStartScreenColumn
              if @invisibles.space?
                text = @invisibles.space.repeat(spaceCount)
              else
                text = ' '.repeat(spaceCount)

              @patch.spliceWithText(
                Point(screenRow, leadingWhitespaceStartScreenColumn),
                Point(0, spaceCount),
                text,
                metadata: {
                  leadingWhitespace: true,
                  invisibleCharacter: @invisibles.space?
                  atomic: atSoftTabBoundary
                  showIndentGuide: (leadingWhitespaceStartScreenColumn % @tabLength) is 0
                }
              )
              leadingWhitespaceStartScreenColumn = screenColumn

          if screenColumn > trailingWhitespaceStartScreenColumn
            spaceCount = screenColumn - trailingWhitespaceStartScreenColumn
            if @invisibles.space?
              text = @invisibles.space.repeat(spaceCount)
            else
              text = ' '.repeat(spaceCount)

            @patch.spliceWithText(
              Point(screenRow, trailingWhitespaceStartScreenColumn),
              Point(0, spaceCount),
              text,
              metadata: {
                trailingWhitespace: true,
                invisibleCharacter: @invisibles.space?,
                atomic: atSoftTabBoundary
                showIndentGuide: isBlankLine and (trailingWhitespaceStartScreenColumn % @tabLength) is 0
              }
            )
            trailingWhitespaceStartScreenColumn = screenColumn

        if foldEndBufferPosition?
          foldStartBufferPosition = Point(bufferRow, bufferColumn)
          foldBufferExtent = traversal(foldEndBufferPosition, foldStartBufferPosition)
          @patch.spliceWithText(Point(screenRow, screenColumn), foldBufferExtent, '⋯', {metadata: {fold: true}})
          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          bufferLine = @buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
          screenColumn += 1
          inLeadingWhitespace = true
          for column in [0...bufferColumn] by 1
            character = bufferLine[column]
            unless character is ' ' or character is '\t'
              inLeadingWhitespace = false
              break
          leadingWhitespaceStartScreenColumn = screenColumn if inLeadingWhitespace
          trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartColumn(bufferLine)
          if bufferColumn >= trailingWhitespaceStartBufferColumn
            trailingWhitespaceStartBufferColumn = bufferColumn
            trailingWhitespaceStartScreenColumn = screenColumn
          else
            trailingWhitespaceStartScreenColumn = Infinity
        else
          if character is '\t'
            distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
            if @invisibles.tab?
              tabText = @invisibles.tab + ' '.repeat(distanceToNextTabStop - 1)
            else
              tabText = ' '.repeat(distanceToNextTabStop)

            @patch.spliceWithText(
              Point(screenRow, screenColumn),
              Point(0, 1),
              tabText,
              metadata: {
                hardTab: true
                atomic: true
                leadingWhitespace: inLeadingWhitespace
                trailingWhitespace: inTrailingWhitespace
                invisibleCharacter: @invisibles.tab?
                showIndentGuide: (inLeadingWhitespace or isBlankLine and inTrailingWhitespace) and distanceToNextTabStop is @tabLength
              }
            )
            bufferColumn += 1
            screenColumn += tabText.length
            leadingWhitespaceStartScreenColumn = screenColumn if inLeadingWhitespace
            trailingWhitespaceStartScreenColumn = screenColumn if inTrailingWhitespace
          else
            bufferColumn += 1
            screenColumn += 1

      if invisibleReplacement = @eolInvisibles[@buffer.lineEndingForRow(bufferRow)]
        @patch.splice(
          Point(screenRow, screenColumn - 1),
          Point(1, 0),
          Point(1, 0),
          {text: invisibleReplacement + "\n", metadata: {eol: true, invisibleCharacter: true}}
        )
      screenLineLengths.push(screenColumn - 1)
      bufferRow += 1
      bufferColumn = 0
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

  # Walk backwards through the line, looking for the first non whitespace
  # character. The trailing whitespace starts *after* that character. If we
  # return the line's length, this means there is no trailing whitespace.
  findTrailingWhitespaceStartColumn: (line) ->
    for character, column in line by -1
      unless character is ' ' or character is '\t'
        return column + 1
    0

  buildTokenIterator: ->
    new TokenIterator(this, @buffer, @patch.buildIterator(), @textDecorationLayer?.buildIterator())

  getText: ->
    text = ''

    {iterator} = @patch
    iterator.rewind()

    loop
      if iterator.inChange()
        text += iterator.getNewText()
      else
        text += @buffer.getTextInRange(Range(iterator.getInputStart(), iterator.getInputEnd()))
      break unless iterator.moveToSuccessor()

    text

  translateBufferPosition: (bufferPosition, options) ->
    bufferPosition = Point.fromObject(bufferPosition)
    bufferPosition = clipNegativePoint(bufferPosition)

    @patchIterator.seekToInputPosition(bufferPosition)
    if @patchIterator.inChange()
      if @patchIterator.getMetadata()?.atomic
        if options?.clipDirection is 'forward'
          screenPosition = @patchIterator.getOutputEnd()
        else
          screenPosition = @patchIterator.getOutputStart()
      else
        screenPosition = @patchIterator.translateInputPosition(bufferPosition)
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
      if @patchIterator.getMetadata()?.atomic
        if options?.clipDirection is 'forward' and comparePoints(screenPosition, @patchIterator.getOutputStart()) > 0
          bufferPosition = @patchIterator.getInputEnd()
        else
          bufferPosition = @patchIterator.getInputStart()
      else
        bufferPosition = @patchIterator.translateOutputPosition(screenPosition)
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
      if @patchIterator.getMetadata()?.atomic
        if options?.clipDirection is 'forward' and comparePoints(screenPosition, @patchIterator.getOutputStart()) > 0
          clippedScreenPosition = @patchIterator.getOutputEnd()
        else
          clippedScreenPosition = @patchIterator.getOutputStart()
      else
        clippedScreenPosition = screenPosition
    else
      bufferPosition = @patchIterator.translateOutputPosition(screenPosition)
      clippedBufferPosition = @buffer.clipPosition(bufferPosition, options)
      clippedScreenPosition =  @patchIterator.translateInputPosition(clippedBufferPosition)

    Point.fromObject(clippedScreenPosition)

  getScreenLineCount: ->
    @clipScreenPosition(Point(Infinity, Infinity)).row + 1

  getRightmostScreenPosition: ->
    @lineLengthIndex.getPointWithMaxLineLength()

  lineLengthForScreenRow: (screenRow) ->
    @lineLengthIndex.lineLengthForRow(screenRow)
