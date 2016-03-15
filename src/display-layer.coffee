Patch = require 'atom-patch'
ScreenLineIndex = require 'atom-screen-line-index'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
EmptyDecorationLayer = require './empty-decoration-layer'
{traverse, traversal, clipNegativePoint} = pointHelpers = require './point-helpers'
comparePoints = pointHelpers.compare
maxPoint = pointHelpers.max
{normalizePatchChanges} = require './helpers'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, @foldsMarkerLayer, @invisibles, @showIndentGuides, @softWrapColumn, @softWrapHangingIndent, @ratioForCharacter}={}) ->
    @displayMarkerLayersById = {}
    @textDecorationLayer = null
    @foldsMarkerLayer ?= @buffer.addMarkerLayer({maintainHistory: true})
    @invisibles ?= {}
    @softWrapColumn ?= Infinity
    @softWrapHangingIndent ?= 0
    @ratioForCharacter ?= -> 1.0
    @eolInvisibles = {
      "\r": @invisibles.cr
      "\n": @invisibles.eol
      "\r\n": @invisibles.cr + @invisibles.eol
    }
    @foldIdCounter = 1
    @disposables = @buffer.onDidChange(@bufferDidChange.bind(this))
    @screenLineIndex = new ScreenLineIndex
    @spatialTokenIterator = @screenLineIndex.buildTokenIterator()
    @screenLineIterator = @screenLineIndex.buildScreenLineIterator()
    @screenLineIndex.splice(0, 0, @buildSpatialTokenLines(0, @buffer.getLineCount()))
    @textDecorationLayer = new EmptyDecorationLayer
    @emitter = new Emitter
    @invalidationCountsByScreenLineId = new Map

  destroy: ->
    @disposables.dispose()
    @foldsMarkerLayer.destroy()
    for id, displayMarkerLayer of @displayMarkerLayersById
      displayMarkerLayer.destroy()

  addMarkerLayer: (options) ->
    markerLayer = new DisplayMarkerLayer(this, @buffer.addMarkerLayer(options))
    @displayMarkerLayersById[markerLayer.id] = markerLayer

  getMarkerLayer: (id) ->
    if bufferMarkerLayer = @buffer.getMarkerLayer(id)
      @displayMarkerLayersById[id] ?= new DisplayMarkerLayer(this, bufferMarkerLayer)

  setTextDecorationLayer: (layer) ->
    @decorationLayerDisposable?.dispose()
    @textDecorationLayer = layer
    @decorationLayerDisposable = layer.onDidInvalidateRange?(@decorationLayerDidInvalidateRange.bind(this))

  foldBufferRange: (bufferRange) ->
    bufferRange = @buffer.clipRange(bufferRange)
    foldId = @foldsMarkerLayer.markRange(bufferRange).id
    if @foldsMarkerLayer.findMarkers(containsRange: bufferRange).length is 1
      {startScreenRow, endScreenRow, startBufferRow, endBufferRow} = @expandBufferRangeToScreenLineBoundaries(bufferRange)
      oldRowExtent = endScreenRow - startScreenRow
      newScreenLines = @buildSpatialTokenLines(startBufferRow, endBufferRow)
      newRowExtent = newScreenLines.length
      @spliceScreenLineIndex(startScreenRow, endScreenRow - startScreenRow, newScreenLines)
      @emitter.emit 'did-change-sync', Object.freeze([{
        start: Point(startScreenRow, 0),
        oldExtent: Point(oldRowExtent, 0),
        newExtent: Point(newRowExtent, 0)
      }])

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
      combinedRange = Range(combinedRangeStart, combinedRangeEnd)
      {startScreenRow, endScreenRow, startBufferRow, endBufferRow} = @expandBufferRangeToScreenLineBoundaries(combinedRange)
      oldRowExtent = endScreenRow - startScreenRow
      newScreenLines = @buildSpatialTokenLines(startBufferRow, endBufferRow)
      newRowExtent = newScreenLines.length
      @spliceScreenLineIndex(startScreenRow, endScreenRow - startScreenRow, newScreenLines)
      @emitter.emit 'did-change-sync', Object.freeze([{
        start: Point(startScreenRow, 0),
        oldExtent: Point(oldRowExtent, 0),
        newExtent: Point(newRowExtent, 0)
      }])

  onDidChangeSync: (callback) ->
    @emitter.on 'did-change-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = @expandChangeRegionToSurroundingEmptyLines(change.oldRange, change.newRange)
    {startScreenRow, endScreenRow, startBufferRow} = @expandBufferRangeToScreenLineBoundaries(oldRange)

    oldRowExtent = endScreenRow - startScreenRow
    newScreenLines = @buildSpatialTokenLines(startBufferRow, newRange.end.row + 1)
    newRowExtent = newScreenLines.length
    @spliceScreenLineIndex(startScreenRow, oldRowExtent, newScreenLines)

    start = Point(startScreenRow, 0)
    oldExtent = Point(oldRowExtent, 0)
    newExtent = Point(newRowExtent, 0)

    combinedChanges = new Patch
    combinedChanges.splice(start, oldExtent, newExtent)

    if @textDecorationLayer?
      invalidatedRanges = @textDecorationLayer.getInvalidatedRanges()
      for range in invalidatedRanges
        range = @translateBufferRange(range)
        @invalidateScreenLines(range)
        range.start.column = 0
        range.end.row++
        range.end.column = 0
        extent = range.getExtent()
        combinedChanges.splice(range.start, extent, extent)

    @emitter.emit 'did-change-sync', Object.freeze(normalizePatchChanges(combinedChanges.getChanges()))

  spliceScreenLineIndex: (startScreenRow, oldRowExtent, newScreenLines) ->
    deletedScreenLineIds = @screenLineIndex.splice(startScreenRow, oldRowExtent, newScreenLines)
    for screenLineId in deletedScreenLineIds
      @invalidationCountsByScreenLineId.delete(screenLineId)
    return

  invalidateScreenLines: (screenRange) ->
    for screenLineId in @screenLineIdsForScreenRange(screenRange)
      count = @invalidationCountsByScreenLineId.get(screenLineId) ? 0
      @invalidationCountsByScreenLineId.set(screenLineId, count + 1)
    return

  decorationLayerDidInvalidateRange: (bufferRange) ->
    screenRange = @translateBufferRange(bufferRange)
    @invalidateScreenLines(screenRange)
    extent = screenRange.getExtent()
    @emitter.emit 'did-change-sync', [{
      start: screenRange.start,
      oldExtent: extent,
      newExtent: extent
    }]

  screenLineIdsForScreenRange: (screenRange) ->
    @screenLineIterator.seekToScreenRow(screenRange.start.row)
    ids = []
    while @screenLineIterator.getScreenRow() <= screenRange.end.row
      ids.push(@screenLineIterator.getId())
      break unless @screenLineIterator.moveToSuccessor()
    ids

  expandChangeRegionToSurroundingEmptyLines: (oldRange, newRange) ->
    oldRange = oldRange.copy()
    newRange = newRange.copy()

    while oldRange.start.row > 0
      break if @buffer.lineForRow(oldRange.start.row - 1).length isnt 0
      oldRange.start.row--
      newRange.start.row--

    while newRange.end.row < @buffer.getLastRow()
      break if @buffer.lineForRow(newRange.end.row + 1).length isnt 0
      oldRange.end.row++
      newRange.end.row++

    {oldRange, newRange}

  expandBufferRangeToScreenLineBoundaries: (range) ->
    @screenLineIterator.seekToBufferPosition(Point(range.start.row, 0))
    startScreenRow = @screenLineIterator.getScreenRow()
    startBufferRow = @screenLineIterator.getBufferStart().row

    @screenLineIterator.seekToBufferPosition(Point(range.end.row, Infinity))
    endScreenRow = @screenLineIterator.getScreenRow() + 1
    endBufferRow = @screenLineIterator.getBufferEnd().row

    {startScreenRow, endScreenRow, startBufferRow, endBufferRow}

  buildSpatialTokenLines: (startBufferRow, endBufferRow) ->
    folds = @computeFoldsInBufferRowRange(startBufferRow, endBufferRow)

    screenLines = []
    bufferRow = startBufferRow
    bufferColumn = 0
    screenColumn = 0
    screenLineWidth = 0

    while bufferRow < endBufferRow
      tokens = []
      tokensScreenExtent = 0
      screenLineBufferStart = Point(bufferRow, 0)
      bufferLine = @buffer.lineForRow(bufferRow)
      bufferLineLength = bufferLine.length
      previousPositionWasFold = false
      trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartColumn(bufferLine)
      isBlankLine = trailingWhitespaceStartBufferColumn is 0
      isEmptyLine = bufferLineLength is 0
      inLeadingWhitespace = not isBlankLine
      lastWrapBufferColumn = 0
      lastWordStartScreenColumn = 0
      lastWordStartBufferColumn = 0
      screenLineWidthAtLastWordStart = 0
      softWrapIndent = null

      while bufferColumn <= bufferLineLength
        character = bufferLine[bufferColumn]
        previousCharacter = bufferLine[bufferColumn - 1]
        foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
        inTrailingWhitespace = bufferColumn >= trailingWhitespaceStartBufferColumn
        trailingWhitespaceStartScreenColumn = screenColumn if bufferColumn is trailingWhitespaceStartBufferColumn

        atSoftTabBoundary =
          (inLeadingWhitespace or isBlankLine and inTrailingWhitespace) and
            (screenColumn % @tabLength) is 0 and (screenColumn - tokensScreenExtent) is @tabLength

        if character isnt ' ' or foldEndBufferPosition? or atSoftTabBoundary
          if inLeadingWhitespace and bufferColumn < bufferLineLength
            unless character is ' ' or character is '\t'
              inLeadingWhitespace = false
              softWrapIndent = screenColumn
            if screenColumn > tokensScreenExtent
              spaceCount = screenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: spaceCount,
                bufferExtent: Point(0, spaceCount),
                metadata: {
                  leadingWhitespace: true,
                  invisibleCharacter: @invisibles.space?,
                  atomic: atSoftTabBoundary,
                  showIndentGuide: (tokensScreenExtent % @tabLength) is 0
                }
              })
              tokensScreenExtent = screenColumn

          if inTrailingWhitespace && screenColumn > tokensScreenExtent
            if trailingWhitespaceStartScreenColumn > tokensScreenExtent
              behindCount = trailingWhitespaceStartScreenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: behindCount,
                bufferExtent: Point(0, behindCount)
              })
              tokensScreenExtent = trailingWhitespaceStartScreenColumn

            if screenColumn > tokensScreenExtent
              spaceCount = screenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: spaceCount,
                bufferExtent: Point(0, spaceCount),
                metadata: {
                  trailingWhitespace: true,
                  invisibleCharacter: @invisibles.space?,
                  atomic: atSoftTabBoundary,
                  showIndentGuide: isBlankLine and (tokensScreenExtent % @tabLength) is 0
                }
              })
              tokensScreenExtent = screenColumn

        if ((previousCharacter is ' ' or previousCharacter is '\t') and
            character isnt ' '  and character isnt '\t')
          lastWordStartScreenColumn = screenColumn
          lastWordStartBufferColumn = bufferColumn
          screenLineWidthAtLastWordStart = screenLineWidth

        if character? and ((screenLineWidth + @ratioForCharacter(character)) > @softWrapColumn)
          if lastWordStartBufferColumn > lastWrapBufferColumn
            wrapScreenColumn = lastWordStartScreenColumn
            wrapBufferColumn = lastWordStartBufferColumn
            screenLineWidthAtWrapColumn = screenLineWidthAtLastWordStart
          else
            wrapScreenColumn = screenColumn
            wrapBufferColumn = bufferColumn
            screenLineWidthAtWrapColumn = screenLineWidth

          if wrapScreenColumn > tokensScreenExtent
            behindCount = wrapScreenColumn - tokensScreenExtent
            tokens.push({
              screenExtent: behindCount,
              bufferExtent: Point(0, behindCount)
            })
            tokensScreenExtent = wrapScreenColumn

          tokens.push({
            screenExtent: 0,
            bufferExtent: Point(0, 0),
            metadata: {void: true, softLineBreak: true}
          })

          screenLineBufferEnd = Point(bufferRow, wrapBufferColumn)
          screenLines.push({
            screenExtent: tokensScreenExtent,
            bufferExtent: traversal(screenLineBufferEnd, screenLineBufferStart),
            tokens
          })
          tokens = []
          tokensScreenExtent = 0
          screenLineBufferStart = screenLineBufferEnd
          screenColumn = screenColumn - wrapScreenColumn
          screenLineWidth = screenLineWidth - screenLineWidthAtWrapColumn
          lastWrapBufferColumn = wrapBufferColumn

          if softWrapIndent < @softWrapColumn
            indentLength = softWrapIndent
          else
            indentLength = 0

          if (indentLength + @softWrapHangingIndent) < @softWrapColumn
            indentLength += + @softWrapHangingIndent

          if indentLength > 0
            tokens.push({
              screenExtent: indentLength,
              bufferExtent: Point.ZERO
              metadata: {void: true, softWrapIndentation: true}
            })
            tokensScreenExtent += indentLength
            screenColumn += indentLength
            screenLineWidth += @ratioForCharacter(' ') * indentLength

        if foldEndBufferPosition?
          if screenColumn > tokensScreenExtent
            behindCount = screenColumn - tokensScreenExtent
            tokens.push({
              screenExtent: behindCount,
              bufferExtent: Point(0, behindCount)
            })
            tokensScreenExtent = screenColumn

          previousPositionWasFold = true
          foldStartBufferPosition = Point(bufferRow, bufferColumn)
          tokens.push({
            screenExtent: 1,
            bufferExtent: traversal(foldEndBufferPosition, foldStartBufferPosition),
            metadata: {fold: true}
          })

          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          bufferLine = @buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
          screenColumn += 1
          screenLineWidth += @ratioForCharacter('⋯')
          tokensScreenExtent = screenColumn
          inLeadingWhitespace = true
          for column in [0...bufferColumn] by 1
            character = bufferLine[column]
            unless character is ' ' or character is '\t'
              inLeadingWhitespace = false
              break
          trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartColumn(bufferLine)
          if bufferColumn >= trailingWhitespaceStartBufferColumn
            trailingWhitespaceStartBufferColumn = bufferColumn
        else
          if character is '\t'
            if screenColumn > tokensScreenExtent
              behindCount = screenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: behindCount,
                bufferExtent: Point(0, behindCount)
              })
              tokensScreenExtent = screenColumn

            distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
            tokens.push({
              screenExtent: distanceToNextTabStop,
              bufferExtent: Point(0, 1),
              metadata: {
                hardTab: true
                atomic: true
                leadingWhitespace: inLeadingWhitespace
                trailingWhitespace: inTrailingWhitespace
                invisibleCharacter: @invisibles.tab?
                showIndentGuide: (inLeadingWhitespace or isBlankLine and inTrailingWhitespace) and distanceToNextTabStop is @tabLength
              }
            })
            bufferColumn += 1
            screenColumn += distanceToNextTabStop
            screenLineWidth += @ratioForCharacter(' ') * distanceToNextTabStop
            tokensScreenExtent = screenColumn
          else
            bufferColumn += 1
            if character?
              screenColumn += 1
              screenLineWidth += @ratioForCharacter(character)

      if screenColumn > tokensScreenExtent
        behindCount = screenColumn - tokensScreenExtent
        tokens.push({
          screenExtent: behindCount,
          bufferExtent: Point(0, behindCount)
        })
        tokensScreenExtent = screenColumn

      indentGuidesCount = @emptyLineIndentationForBufferRow(bufferRow)

      if eolInvisibleReplacement = @eolInvisibles[@buffer.lineEndingForRow(bufferRow)]
        tokens.push({
          screenExtent: eolInvisibleReplacement.length,
          bufferExtent: Point(0, 0),
          metadata: {
            eol: eolInvisibleReplacement,
            invisibleCharacter: true,
            showIndentGuide: isEmptyLine and @showIndentGuides and indentGuidesCount > 0,
            void: true
          }
        })
        screenColumn += eolInvisibleReplacement.length
        tokensScreenExtent = screenColumn

      while @showIndentGuides and indentGuidesCount > 0 and not previousPositionWasFold
        distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
        tokens.push({
          screenExtent: distanceToNextTabStop,
          bufferExtent: Point(0, 0),
          metadata: {
            showIndentGuide: (screenColumn % @tabLength is 0),
            void: true
          }
        })
        screenColumn += distanceToNextTabStop
        tokensScreenExtent = screenColumn
        indentGuidesCount--

      # this creates a non-void position at the beginning of an empty line, even
      # if it has void eol or indent guide tokens.
      if isEmptyLine
        tokens.unshift({screenExtent: 0, bufferExtent: Point(0, 0)})

      bufferRow += 1
      bufferColumn = 0
      screenColumn = 0
      screenLines.push({
        screenExtent: tokensScreenExtent,
        bufferExtent: traversal(Point(bufferRow, bufferColumn), screenLineBufferStart),
        tokens
      })
      tokens = []
      screenLineWidth = 0

    screenLines

  # Given a buffer row range, compute an index of all folds that appear on
  # screen lines containing this range. Returns a folds object mapping startRow
  # to startColumn to endPosition. This object will be referenced when updating
  # the patch to skip folded regions of the buffer.
  computeFoldsInBufferRowRange: (startBufferRow, endBufferRow) ->
    folds = {}
    foldMarkers = @foldsMarkerLayer.findMarkers(intersectsRowRange: [startBufferRow, endBufferRow - 1])
    if foldMarkers.length > 0
      # Index fold end positions by their start row and start column.
      i = 0
      while i < foldMarkers.length
        foldStart = foldMarkers[i].getStartPosition()
        foldEnd = foldMarkers[i].getEndPosition()

        # Process subsequent folds that intersect the current fold.
        loop
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

    folds

  emptyLineIndentationForBufferRow: (bufferRow) ->
    return 0 if @buffer.lineForRow(bufferRow).length > 0

    previousBufferRow = bufferRow - 1
    nextBufferRow = bufferRow + 1
    loop
      previousLine = @buffer.lineForRow(previousBufferRow--)
      break if not previousLine? or previousLine.length > 0
    loop
      nextLine = @buffer.lineForRow(nextBufferRow++)
      break if not nextLine? or nextLine.length > 0

    maxLeadingWhitespace = 0
    if previousLine?
      maxLeadingWhitespace = Math.max(maxLeadingWhitespace, @findLeadingWhitespaceEndColumn(previousLine))
    if nextLine?
      maxLeadingWhitespace = Math.max(maxLeadingWhitespace, @findLeadingWhitespaceEndColumn(nextLine))

    Math.floor(maxLeadingWhitespace / @tabLength)

  # Walk forward through the line, looking for the first non whitespace
  # character and expanding tabs as we go. If we return 0, this means there is
  # no leading whitespace.
  findLeadingWhitespaceEndColumn: (line) ->
    for character, column in line by 1
      return column unless character is ' ' or character is '\t'
    line.length

  # Walk backwards through the line, looking for the first non whitespace
  # character. The trailing whitespace starts *after* that character. If we
  # return the line's length, this means there is no trailing whitespace.
  findTrailingWhitespaceStartColumn: (line) ->
    for character, column in line by -1
      unless character is ' ' or character is '\t'
        return column + 1
    0

  getText: ->
    lines = []
    for screenLine in @getScreenLines()
      line = ''
      for token in screenLine.tokens
        line += token.text
      lines.push(line)
    lines.join('\n')

  getScreenLines: (startRow=0, endRow=@getScreenLineCount()) ->
    decorationIterator = @textDecorationLayer.buildIterator()
    screenLines = []
    @screenLineIterator.seekToScreenRow(startRow)
    containingTags = decorationIterator.seek(@screenLineIterator.getBufferStart())

    while @screenLineIterator.getScreenRow() < endRow
      bufferStart = @screenLineIterator.getBufferStart()
      tokens = []
      spatialDecoration = null
      closeTags = []
      openTags = containingTags.slice()
      atLineStart = true

      if comparePoints(decorationIterator.getPosition(), bufferStart) < 0
        bufferRow = decorationIterator.getPosition().row
        throw new Error("""
          Invalid text decoration iterator position: #{decorationIterator.getPosition()}.
          Buffer row #{bufferRow} has length #{@buffer.lineLengthForRow(bufferRow)}.
        """)

      for {screenExtent, bufferExtent, metadata} in @screenLineIterator.getTokens()
        spatialTokenBufferEnd = traverse(bufferStart, bufferExtent)
        tagsToClose = []
        tagsToOpen = []

        if metadata?.fold
          @updateTags(closeTags, openTags, containingTags, containingTags.slice().reverse(), [], atLineStart)
          tagsToReopenAfterFold = decorationIterator.seek(spatialTokenBufferEnd)
          while comparePoints(decorationIterator.getPosition(), spatialTokenBufferEnd) is 0
            for closeTag in decorationIterator.getCloseTags()
              tagsToReopenAfterFold.splice(tagsToReopenAfterFold.lastIndexOf(closeTag), 1)
            tagsToReopenAfterFold.push(decorationIterator.getOpenTags()...)
            decorationIterator.moveToSuccessor()
        else
          if spatialDecoration?
            tagsToClose.push(spatialDecoration)

          if tagsToReopenAfterFold?
            tagsToOpen.push(tagsToReopenAfterFold...)
            tagsToReopenAfterFold = null

          if comparePoints(decorationIterator.getPosition(), bufferStart) is 0
            tagsToClose.push(decorationIterator.getCloseTags()...)
            tagsToOpen.push(decorationIterator.getOpenTags()...)
            decorationIterator.moveToSuccessor()

        if spatialDecoration = @getSpatialTokenTextDecoration(metadata)
          tagsToOpen.push(spatialDecoration)

        @updateTags(closeTags, openTags, containingTags, tagsToClose, tagsToOpen, atLineStart)

        text = @buildTokenText(metadata, screenExtent, bufferStart, spatialTokenBufferEnd)
        startIndex = 0
        while comparePoints(decorationIterator.getPosition(), spatialTokenBufferEnd) < 0
          endIndex = startIndex + decorationIterator.getPosition().column - bufferStart.column
          tokens.push({closeTags, openTags, text: text.substring(startIndex, endIndex)})
          bufferStart = decorationIterator.getPosition()
          startIndex = endIndex
          closeTags = []
          openTags = []
          @updateTags(closeTags, openTags, containingTags, decorationIterator.getCloseTags(), decorationIterator.getOpenTags())
          decorationIterator.moveToSuccessor()

        tokens.push({closeTags, openTags, text: text.substring(startIndex)})

        closeTags = []
        openTags = []
        bufferStart = spatialTokenBufferEnd
        atLineStart = false

      if containingTags.length > 0
        tokens.push({closeTags: containingTags.slice().reverse(), openTags: [], text: ''})

      if tagsToReopenAfterFold?
        containingTags = tagsToReopenAfterFold
        tagsToReopenAfterFold = null
      else if spatialDecoration?
        containingTags.splice(containingTags.indexOf(spatialDecoration), 1)

      while comparePoints(decorationIterator.getPosition(), spatialTokenBufferEnd) is 0
        @updateTags(closeTags, openTags, containingTags, decorationIterator.getCloseTags(), decorationIterator.getOpenTags())
        decorationIterator.moveToSuccessor()

      screenLineId = @screenLineIterator.getId()
      invalidationCount = @invalidationCountsByScreenLineId.get(screenLineId) ? 0
      screenLines.push({id: "#{screenLineId}-#{invalidationCount}", tokens})
      break unless @screenLineIterator.moveToSuccessor()
    screenLines

  buildTokenText: (metadata, screenExtent, bufferStart, bufferEnd) ->
    if metadata?.hardTab
      if @invisibles.tab?
        @invisibles.tab + ' '.repeat(screenExtent - 1)
      else
        ' '.repeat(screenExtent)
    else if (metadata?.leadingWhitespace or metadata?.trailingWhitespace) and @invisibles.space?
      @invisibles.space.repeat(screenExtent)
    else if metadata?.fold
      '⋯'
    else if metadata?.void
      if metadata?.eol?
        metadata.eol
      else
        ' '.repeat(screenExtent)
    else
      @buffer.getTextInRange(Range(bufferStart, bufferEnd))

  updateTags: (closeTags, openTags, containingTags, tagsToClose, tagsToOpen, atLineStart) ->
    if atLineStart
      for closeTag in tagsToClose
        openTags.splice(openTags.lastIndexOf(closeTag), 1)
        containingTags.splice(containingTags.lastIndexOf(closeTag), 1)
    else
      tagsToCloseCounts = {}
      for tag in tagsToClose
        tagsToCloseCounts[tag] ?= 0
        tagsToCloseCounts[tag]++

      containingTagsIndex = containingTags.length
      for closeTag in tagsToClose when tagsToCloseCounts[closeTag] > 0
        while mostRecentOpenTag = containingTags[--containingTagsIndex]
          if mostRecentOpenTag is closeTag
            containingTags.splice(containingTagsIndex, 1)
            break

          closeTags.push(mostRecentOpenTag)
          if tagsToCloseCounts[mostRecentOpenTag] > 0
            containingTags.splice(containingTagsIndex, 1)
            tagsToCloseCounts[mostRecentOpenTag]--
          else
            openTags.unshift(mostRecentOpenTag)
        closeTags.push(closeTag)

    openTags.push(tagsToOpen...)
    containingTags.push(tagsToOpen...)

  getSpatialTokenTextDecoration: (metadata) ->
    if metadata
      decoration = ''
      decoration += 'invisible-character ' if metadata.invisibleCharacter
      decoration += 'hard-tab ' if metadata.hardTab
      decoration += 'leading-whitespace ' if metadata.leadingWhitespace
      decoration += 'trailing-whitespace ' if metadata.trailingWhitespace
      decoration += 'eol ' if metadata.eol
      decoration += 'indent-guide ' if metadata.showIndentGuide and @showIndentGuides
      decoration += 'fold-marker ' if metadata.fold
      if decoration.length > 0
        decoration.trim()

  translateBufferPosition: (bufferPosition, options) ->
    bufferPosition = @buffer.clipPosition(bufferPosition, options)
    clipDirection = options?.clipDirection

    @spatialTokenIterator.seekToBufferPosition(bufferPosition)

    if @spatialTokenIterator.getMetadata()?.softLineBreak or @spatialTokenIterator.getMetadata()?.softWrapIndentation
      clipDirection = 'forward'

    while @spatialTokenIterator.getMetadata()?.void
      if clipDirection is 'forward'
        if @spatialTokenIterator.moveToSuccessor()
          bufferPosition = @spatialTokenIterator.getBufferStart()
        else
          clipDirection = 'backward'
      else
        @spatialTokenIterator.moveToPredecessor()
        bufferPosition = @spatialTokenIterator.getBufferEnd()

    if @spatialTokenIterator.getMetadata()?.atomic
      if comparePoints(bufferPosition, @spatialTokenIterator.getBufferStart()) is 0
        screenPosition = @spatialTokenIterator.getScreenStart()
      else if comparePoints(bufferPosition, @spatialTokenIterator.getBufferEnd()) is 0 or options?.clipDirection is 'forward'
        screenPosition = @spatialTokenIterator.getScreenEnd()
      else
        screenPosition = @spatialTokenIterator.getBufferStart()
    else
      screenPosition = @spatialTokenIterator.translateBufferPosition(bufferPosition)

    Point.fromObject(screenPosition)

  translateBufferRange: (bufferRange, options) ->
    bufferRange = Range.fromObject(bufferRange)
    start = @translateBufferPosition(bufferRange.start, options)
    end = @translateBufferPosition(bufferRange.end, options)
    Range(start, end)

  translateScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)
    clipDirection = options?.clipDirection

    @spatialTokenIterator.seekToScreenPosition(screenPosition)

    while @spatialTokenIterator.getMetadata()?.void
      if @spatialTokenIterator.getMetadata().eol and comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        break

      if (clipDirection is 'forward' or
          (options?.skipSoftWrapIndentation and @spatialTokenIterator.getMetadata().softWrapIndentation))
        if @spatialTokenIterator.moveToSuccessor()
          screenPosition = @spatialTokenIterator.getScreenStart()
        else
          clipDirection = 'backward'
      else
        {softLineBreak} = @spatialTokenIterator.getMetadata()
        @spatialTokenIterator.moveToPredecessor()
        screenPosition = @spatialTokenIterator.getScreenEnd()
        screenPosition = traverse(screenPosition, Point(0, -1)) if softLineBreak

    if @spatialTokenIterator.getMetadata()?.atomic
      if comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        bufferPosition = @spatialTokenIterator.getBufferStart()
      else if comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) is 0 or options?.clipDirection is 'forward'
        bufferPosition = @spatialTokenIterator.getBufferEnd()
      else
        bufferPosition = @spatialTokenIterator.getBufferStart()
    else
      bufferPosition = @spatialTokenIterator.translateScreenPosition(screenPosition)

    if comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) > 0
      bufferPosition = @buffer.clipPosition(bufferPosition, options)

    Point.fromObject(bufferPosition)

  translateScreenRange: (screenRange, options) ->
    screenRange = Range.fromObject(screenRange)
    start = @translateScreenPosition(screenRange.start, options)
    end = @translateScreenPosition(screenRange.end, options)
    Range(start, end)

  clipScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = clipNegativePoint(screenPosition)
    clipDirection = options?.clipDirection

    @spatialTokenIterator.seekToScreenPosition(screenPosition)

    while @spatialTokenIterator.getMetadata()?.void
      if @spatialTokenIterator.getMetadata().eol and comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        break

      if (clipDirection is 'forward' or
          (options?.skipSoftWrapIndentation and @spatialTokenIterator.getMetadata().softWrapIndentation))
        if @spatialTokenIterator.moveToSuccessor()
          screenPosition = @spatialTokenIterator.getScreenStart()
        else
          clipDirection = 'backward'
      else
        {softLineBreak} = @spatialTokenIterator.getMetadata()
        @spatialTokenIterator.moveToPredecessor()
        screenPosition = @spatialTokenIterator.getScreenEnd()
        screenPosition = traverse(screenPosition, Point(0, -1)) if softLineBreak

    if comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) <= 0
      if (@spatialTokenIterator.getMetadata()?.atomic and
          comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) > 0 and
          comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) < 0)
        if options?.clipDirection is 'forward'
          screenPosition = @spatialTokenIterator.getScreenEnd()
        else
          screenPosition = @spatialTokenIterator.getScreenStart()
    else
      if options?.clipDirection is 'forward' and @spatialTokenIterator.moveToSuccessor()
        screenPosition = @spatialTokenIterator.getScreenStart()
      else
        screenPosition = @spatialTokenIterator.getScreenEnd()

    Point.fromObject(screenPosition)

  getScreenLineCount: ->
    @screenLineIndex.getScreenLineCount()

  getRightmostScreenPosition: ->
    @screenLineIndex.getScreenPositionWithMaxLineLength() or {row: 0, column: 0}

  lineLengthForScreenRow: (screenRow) ->
    @screenLineIndex.lineLengthForScreenRow(screenRow) or 0
