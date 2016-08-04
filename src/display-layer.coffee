Patch = require 'atom-patch'
DisplayIndex = require 'display-index'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
DisplayMarkerLayer = require './display-marker-layer'
EmptyDecorationLayer = require './empty-decoration-layer'
{traverse, traversal, clipNegativePoint} = pointHelpers = require './point-helpers'
comparePoints = pointHelpers.compare
maxPoint = pointHelpers.max
{normalizePatchChanges} = require './helpers'
isCharacterPair = require './is-character-pair'

VOID = 1 << 0
ATOMIC = 1 << 1
INVISIBLE_CHARACTER = 1 << 2
FOLD = 1 << 3
HARD_TAB = 1 << 4
LEADING_WHITESPACE = 1 << 5
TRAILING_WHITESPACE = 1 << 6
SHOW_INDENT_GUIDE = 1 << 7
SOFT_LINE_BREAK = 1 << 8
SOFT_WRAP_INDENTATION = 1 << 9
LINE_ENDING = 1 << 10
CR = 1 << 11
LF = 1 << 12

isWordStart = (previousCharacter, character) ->
  (previousCharacter is ' ' or previousCharacter is '\t') and
  (character isnt ' '  and character isnt '\t')

spatialTokenTextDecorationCache = new Map
getSpatialTokenTextDecoration = (metadata) ->
  if metadata
    if spatialTokenTextDecorationCache.has(metadata)
      spatialTokenTextDecorationCache.get(metadata)
    else
      decoration = ''
      decoration += 'invisible-character ' if metadata & INVISIBLE_CHARACTER
      decoration += 'hard-tab ' if metadata & HARD_TAB
      decoration += 'leading-whitespace ' if metadata & LEADING_WHITESPACE
      decoration += 'trailing-whitespace ' if metadata & TRAILING_WHITESPACE
      decoration += 'eol ' if metadata & LINE_ENDING
      decoration += 'indent-guide ' if (metadata & SHOW_INDENT_GUIDE)
      decoration += 'fold-marker ' if metadata & FOLD
      if decoration.length > 0
        decoration = decoration.trim()
      else
        decoration = undefined
      spatialTokenTextDecorationCache.set(metadata, decoration)
      decoration

module.exports =
class DisplayLayer
  # Used in test
  VOID_TOKEN: VOID
  ATOMIC_TOKEN: ATOMIC

  @deserialize: (buffer, params) ->
    foldsMarkerLayer = buffer.getMarkerLayer(params.foldsMarkerLayerId)
    new DisplayLayer(params.id, buffer, {foldsMarkerLayer})

  constructor: (@id, @buffer, settings={}) ->
    @displayMarkerLayersById = {}
    @textDecorationLayer = null
    @foldsMarkerLayer = settings.foldsMarkerLayer ? @buffer.addMarkerLayer({
      maintainHistory: false,
      persistent: true,
      destroyInvalidatedMarkers: true
    })
    @foldIdCounter = 1
    @disposables = @buffer.onDidChange(@bufferDidChange.bind(this))
    @displayIndex = new DisplayIndex
    @spatialTokenIterator = @displayIndex.buildTokenIterator()
    @spatialLineIterator = @displayIndex.buildScreenLineIterator()
    @textDecorationLayer = new EmptyDecorationLayer
    @emitter = new Emitter
    @invalidationCountsBySpatialLineId = new Map
    @screenLinesBySpatialLineId = new Map
    @codesByTag = new Map
    @tagsByCode = new Map
    @nextOpenTagCode = -1
    @reset({
      invisibles: settings.invisibles ? {}
      tabLength: settings.tabLength ? 4
      softWrapColumn: settings.softWrapColumn ? Infinity
      softWrapHangingIndent: settings.softWrapHangingIndent ? 0
      showIndentGuides: settings.showIndentGuides ? false,
      ratioForCharacter: settings.ratioForCharacter ? -> 1.0,
      isWrapBoundary: settings.isWrapBoundary ? isWordStart
      foldCharacter: settings.foldCharacter ? '⋯'
      atomicSoftTabs: settings.atomicSoftTabs ? true
    })

  serialize: ->
    {id: @id, foldsMarkerLayerId: @foldsMarkerLayer.id}

  copy: ->
    newId = @buffer.nextDisplayLayerId++
    foldsMarkerLayer = @foldsMarkerLayer.copy()
    copy = new DisplayLayer(newId, @buffer, {
      foldsMarkerLayer, @tabLength, @invisibles, @showIndentGuides,
      @softWrapColumn, @softWrapHangingIndent, @ratioForCharacter, @isWrapBoundary
    })
    @buffer.displayLayers[newId] = copy

  destroy: ->
    @disposables.dispose()
    @foldsMarkerLayer.destroy()
    for id, displayMarkerLayer of @displayMarkerLayersById
      displayMarkerLayer.destroy()
    delete @buffer.displayLayers[@id]

  reset: (params) ->
    @tabLength = params.tabLength if params.hasOwnProperty('tabLength')
    @invisibles = params.invisibles if params.hasOwnProperty('invisibles')
    @showIndentGuides = params.showIndentGuides if params.hasOwnProperty('showIndentGuides')
    @softWrapColumn = params.softWrapColumn if params.hasOwnProperty('softWrapColumn')
    @softWrapHangingIndent = params.softWrapHangingIndent if params.hasOwnProperty('softWrapHangingIndent')
    @ratioForCharacter = params.ratioForCharacter if params.hasOwnProperty('ratioForCharacter')
    @isWrapBoundary = params.isWrapBoundary if params.hasOwnProperty('isWrapBoundary')
    @foldCharacter = params.foldCharacter if params.hasOwnProperty('foldCharacter')
    @atomicSoftTabs = params.atomicSoftTabs if params.hasOwnProperty('foldCharacter')

    @eolInvisibles = {
      "\r": @invisibles.cr
      "\n": @invisibles.eol
      "\r\n": @invisibles.cr + @invisibles.eol
    }

    {startScreenRow, endScreenRow} = @expandBufferRangeToLineBoundaries(Range(Point.ZERO, Point(@buffer.getLineCount(), 0)))
    newLines = @buildSpatialScreenLines(0, @buffer.getLineCount())
    oldRowExtent = endScreenRow - startScreenRow
    newRowExtent = newLines.length
    @spliceDisplayIndex(startScreenRow, oldRowExtent, newLines)
    @emitter.emit 'did-change-sync', Object.freeze([{
      start: Point(startScreenRow, 0),
      oldExtent: Point(oldRowExtent, 0),
      newExtent: Point(newRowExtent, 0)
    }])
    @notifyObserversIfMarkerScreenPositionsChanged()

  addMarkerLayer: (options) ->
    markerLayer = new DisplayMarkerLayer(this, @buffer.addMarkerLayer(options), true)
    @displayMarkerLayersById[markerLayer.id] = markerLayer

  getMarkerLayer: (id) ->
    if bufferMarkerLayer = @buffer.getMarkerLayer(id)
      @displayMarkerLayersById[id] ?= new DisplayMarkerLayer(this, bufferMarkerLayer, false)

  notifyObserversIfMarkerScreenPositionsChanged: ->
    for id, displayMarkerLayer of @displayMarkerLayersById
      displayMarkerLayer.notifyObserversIfMarkerScreenPositionsChanged()

  setTextDecorationLayer: (layer) ->
    @decorationLayerDisposable?.dispose()
    @textDecorationLayer = layer
    @decorationLayerDisposable = layer.onDidInvalidateRange?(@decorationLayerDidInvalidateRange.bind(this))

  bufferRangeForFold: (id) ->
    @foldsMarkerLayer.getMarkerRange(id)

  foldBufferRange: (bufferRange) ->
    bufferRange = @buffer.clipRange(bufferRange)
    foldMarker = @foldsMarkerLayer.markRange(bufferRange, {invalidate: 'overlap', exclusive: true})
    if @findFoldMarkers({containsRange: bufferRange, valid: true}).length is 1
      {startScreenRow, endScreenRow, startBufferRow, endBufferRow} = @expandBufferRangeToLineBoundaries(bufferRange)
      oldRowExtent = endScreenRow - startScreenRow
      newScreenLines = @buildSpatialScreenLines(startBufferRow, endBufferRow)
      newRowExtent = newScreenLines.length
      @spliceDisplayIndex(startScreenRow, oldRowExtent, newScreenLines)
      @emitter.emit 'did-change-sync', Object.freeze([{
        start: Point(startScreenRow, 0),
        oldExtent: Point(oldRowExtent, 0),
        newExtent: Point(newRowExtent, 0)
      }])
      @notifyObserversIfMarkerScreenPositionsChanged()

    foldMarker.id

  foldsIntersectingBufferRange: (bufferRange) ->
    @findFoldMarkers(intersectsRange: bufferRange).map ({id}) -> id

  findFoldMarkers: (params) ->
    params.valid = true
    @foldsMarkerLayer.findMarkers(params)

  destroyFold: (foldId) ->
    if foldMarker = @foldsMarkerLayer.getMarker(foldId)
      @destroyFoldMarkers([foldMarker])

  destroyFoldsIntersectingBufferRange: (bufferRange) ->
    bufferRange = @buffer.clipRange(bufferRange)
    @destroyFoldMarkers(@findFoldMarkers(intersectsRange: bufferRange))

  destroyAllFolds: ->
    @destroyFoldMarkers(@foldsMarkerLayer.getMarkers())

  destroyFoldMarkers: (foldMarkers) ->
    return [] if foldMarkers.length is 0

    combinedRangeStart = combinedRangeEnd = foldMarkers[0].getStartPosition()
    for foldMarker in foldMarkers
      combinedRangeEnd = maxPoint(combinedRangeEnd, foldMarker.getEndPosition())
      foldMarker.destroy()
    combinedRange = Range(combinedRangeStart, combinedRangeEnd)
    {startScreenRow, endScreenRow, startBufferRow, endBufferRow} = @expandBufferRangeToLineBoundaries(combinedRange)
    oldRowExtent = endScreenRow - startScreenRow
    newScreenLines = @buildSpatialScreenLines(startBufferRow, endBufferRow)
    newRowExtent = newScreenLines.length
    @spliceDisplayIndex(startScreenRow, oldRowExtent, newScreenLines)
    @emitter.emit 'did-change-sync', Object.freeze([{
      start: Point(startScreenRow, 0),
      oldExtent: Point(oldRowExtent, 0),
      newExtent: Point(newRowExtent, 0)
    }])
    @notifyObserversIfMarkerScreenPositionsChanged()

    foldMarkers.map((marker) -> marker.getRange())

  onDidChangeSync: (callback) ->
    @emitter.on 'did-change-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = @expandChangeRegionToSurroundingEmptyLines(change.oldRange, change.newRange)

    {startScreenRow, endScreenRow, startBufferRow, endBufferRow} = @expandBufferRangeToLineBoundaries(oldRange)
    endBufferRow = newRange.end.row + (endBufferRow - oldRange.end.row)

    oldRowExtent = endScreenRow - startScreenRow
    newScreenLines = @buildSpatialScreenLines(startBufferRow, endBufferRow)
    newRowExtent = newScreenLines.length
    @spliceDisplayIndex(startScreenRow, oldRowExtent, newScreenLines)

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

  spliceDisplayIndex: (startScreenRow, oldRowExtent, newScreenLines) ->
    deletedSpatialLineIds = @displayIndex.splice(startScreenRow, oldRowExtent, newScreenLines)
    for id in deletedSpatialLineIds
      @invalidationCountsBySpatialLineId.delete(id)
      @screenLinesBySpatialLineId.delete(id)
    return

  invalidateScreenLines: (screenRange) ->
    for id in @spatialLineIdsForScreenRange(screenRange)
      invalidationCount = @invalidationCountsBySpatialLineId.get(id) ? 0
      @invalidationCountsBySpatialLineId.set(id, invalidationCount + 1)
      @screenLinesBySpatialLineId.delete(id)
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

  spatialLineIdsForScreenRange: (screenRange) ->
    @spatialLineIterator.seekToScreenRow(screenRange.start.row)
    ids = []
    while @spatialLineIterator.getScreenRow() <= screenRange.end.row
      ids.push(@spatialLineIterator.getId())
      break unless @spatialLineIterator.moveToSuccessor()
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

  lineStartBoundaryForBufferRow: (bufferRow) ->
    @spatialLineIterator.seekToBufferPosition(Point(bufferRow, 0))
    while @spatialLineIterator.isSoftWrappedAtStart()
      @spatialLineIterator.moveToPredecessor()

    {screenRow: @spatialLineIterator.getScreenRow(), bufferRow: @spatialLineIterator.getBufferStart().row}

  lineEndBoundaryForBufferRow: (bufferRow) ->
    @spatialLineIterator.seekToBufferPosition(Point(bufferRow, Infinity))
    while @spatialLineIterator.isSoftWrappedAtEnd()
      @spatialLineIterator.moveToSuccessor()

    {
      screenRow: @spatialLineIterator.getScreenRow() + 1,
      bufferRow: @spatialLineIterator.getBufferEnd().row
    }

  expandBufferRangeToLineBoundaries: (range) ->
    {screenRow: startScreenRow, bufferRow: startBufferRow} = @lineStartBoundaryForBufferRow(range.start.row)
    {screenRow: endScreenRow, bufferRow: endBufferRow} = @lineEndBoundaryForBufferRow(range.end.row)

    {startScreenRow, endScreenRow, startBufferRow, endBufferRow}

  buildSpatialScreenLines: (startBufferRow, endBufferRow) ->
    {startBufferRow, endBufferRow, folds} = @computeFoldsInBufferRowRange(startBufferRow, endBufferRow)

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
      trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartBufferColumn(bufferLine)
      isBlankLine = trailingWhitespaceStartBufferColumn is 0
      isEmptyLine = bufferLineLength is 0
      inLeadingWhitespace = not isBlankLine
      continuingSoftWrappedLine = false
      lastWrapBufferColumn = 0
      wrapBoundaryScreenColumn = 0
      wrapBoundaryBufferColumn = 0
      screenLineWidthAtWrapCharacter = 0
      wrapBoundaryEndsLeadingWhitespace = true
      softWrapIndent = null

      while bufferColumn <= bufferLineLength
        previousCharacter = bufferLine[bufferColumn - 1]
        character = bufferLine[bufferColumn]
        nextCharacter = bufferLine[bufferColumn + 1]
        foldEndBufferPosition = folds[bufferRow]?[bufferColumn]
        if not character?
          characterWidth = 0
        else if foldEndBufferPosition?
          characterWidth = @ratioForCharacter(@foldCharacter)
        else if character is '\t'
          distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
          characterWidth = @ratioForCharacter(' ') * distanceToNextTabStop
        else
          characterWidth = @ratioForCharacter(character)
        inTrailingWhitespace = bufferColumn >= trailingWhitespaceStartBufferColumn
        trailingWhitespaceStartScreenColumn = screenColumn if bufferColumn is trailingWhitespaceStartBufferColumn

        atSoftTabBoundary =
          (inLeadingWhitespace or isBlankLine and inTrailingWhitespace) and
            (screenColumn % @tabLength) is 0 and (screenColumn - tokensScreenExtent) is @tabLength

        if character? and @isWrapBoundary(previousCharacter, character)
          wrapBoundaryScreenColumn = screenColumn
          wrapBoundaryBufferColumn = bufferColumn
          screenLineWidthAtWrapCharacter = screenLineWidth
          wrapBoundaryEndsLeadingWhitespace = inLeadingWhitespace

        if character isnt ' ' or foldEndBufferPosition? or atSoftTabBoundary
          if inLeadingWhitespace and bufferColumn < bufferLineLength
            unless character is ' ' or character is '\t'
              inLeadingWhitespace = false
              softWrapIndent = screenColumn
            if screenColumn > tokensScreenExtent
              spaceCount = screenColumn - tokensScreenExtent
              metadata = LEADING_WHITESPACE
              metadata |= INVISIBLE_CHARACTER if @invisibles.space?
              metadata |= ATOMIC if atSoftTabBoundary and @atomicSoftTabs
              metadata |= SHOW_INDENT_GUIDE if @showIndentGuides and (tokensScreenExtent % @tabLength) is 0
              tokens.push({
                screenExtent: spaceCount,
                bufferExtent: Point(0, spaceCount),
                metadata
              })
              tokensScreenExtent = screenColumn

          if inTrailingWhitespace && screenColumn > tokensScreenExtent
            if trailingWhitespaceStartScreenColumn > tokensScreenExtent
              behindCount = trailingWhitespaceStartScreenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: behindCount,
                bufferExtent: Point(0, behindCount)
                metadata: 0
              })
              tokensScreenExtent = trailingWhitespaceStartScreenColumn

            if screenColumn > tokensScreenExtent
              spaceCount = screenColumn - tokensScreenExtent
              metadata = TRAILING_WHITESPACE
              metadata |= INVISIBLE_CHARACTER if @invisibles.space?
              metadata |= ATOMIC if atSoftTabBoundary
              metadata |= SHOW_INDENT_GUIDE if @showIndentGuides and isBlankLine and (tokensScreenExtent % @tabLength) is 0
              tokens.push({
                screenExtent: spaceCount,
                bufferExtent: Point(0, spaceCount),
                metadata
              })
              tokensScreenExtent = screenColumn

        if character? and nextCharacter? and isCharacterPair(character, nextCharacter)
          if screenColumn > tokensScreenExtent
            behindCount = screenColumn - tokensScreenExtent
            tokens.push({
              screenExtent: behindCount,
              bufferExtent: Point(0, behindCount)
              metadata: 0
            })
            tokensScreenExtent = screenColumn

          tokens.push({
            screenExtent: 2,
            bufferExtent: Point(0, 2),
            metadata: ATOMIC
          })

          bufferColumn += 2
          screenColumn += 2
          tokensScreenExtent += 2
          screenLineWidth += 2
          continue

        if character? and ((screenLineWidth + characterWidth) > @softWrapColumn) and screenColumn > 0
          if wrapBoundaryBufferColumn > lastWrapBufferColumn and not wrapBoundaryEndsLeadingWhitespace
            wrapScreenColumn = wrapBoundaryScreenColumn
            wrapBufferColumn = wrapBoundaryBufferColumn
            screenLineWidthAtWrapColumn = screenLineWidthAtWrapCharacter
          else
            wrapScreenColumn = screenColumn
            wrapBufferColumn = bufferColumn
            screenLineWidthAtWrapColumn = screenLineWidth

          if inTrailingWhitespace and trailingWhitespaceStartScreenColumn > tokensScreenExtent
            behindCount = trailingWhitespaceStartScreenColumn - tokensScreenExtent
            tokens.push({
              screenExtent: behindCount,
              bufferExtent: Point(0, behindCount)
              metadata: 0
            })
            tokensScreenExtent = trailingWhitespaceStartScreenColumn

          if wrapScreenColumn >= tokensScreenExtent
            behindCount = wrapScreenColumn - tokensScreenExtent
            if behindCount > 0
              metadata = 0
              if inTrailingWhitespace
                metadata |= TRAILING_WHITESPACE
                metadata |= INVISIBLE_CHARACTER if @invisibles.space?
              tokens.push({
                screenExtent: behindCount,
                bufferExtent: Point(0, behindCount)
                metadata
              })
          else
            excessTokensScreenExtent = tokensScreenExtent - wrapScreenColumn
            excessTokens = @truncateTokens(tokens, tokensScreenExtent, wrapScreenColumn)

          tokens.push({
            screenExtent: 0,
            bufferExtent: Point(0, 0),
            metadata: VOID | SOFT_LINE_BREAK
          })

          tokensScreenExtent = wrapScreenColumn
          screenLineBufferEnd = Point(bufferRow, wrapBufferColumn)
          screenLines.push({
            screenExtent: tokensScreenExtent,
            bufferExtent: traversal(screenLineBufferEnd, screenLineBufferStart),
            tokens,
            softWrappedAtStart: continuingSoftWrappedLine,
            softWrappedAtEnd: true
          })
          continuingSoftWrappedLine = true
          tokens = []
          tokensScreenExtent = 0
          screenLineBufferStart = screenLineBufferEnd
          screenColumn = screenColumn - wrapScreenColumn
          screenLineWidth = screenLineWidth - screenLineWidthAtWrapColumn
          lastWrapBufferColumn = wrapBufferColumn
          trailingWhitespaceStartScreenColumn = 0 if inTrailingWhitespace

          if softWrapIndent < @softWrapColumn
            indentLength = softWrapIndent
          else
            indentLength = 0

          if (indentLength + @softWrapHangingIndent) < @softWrapColumn
            indentLength += + @softWrapHangingIndent

          if indentLength > 0
            if @showIndentGuides
              indentGuidesCount = Math.ceil(indentLength / @tabLength)
              while indentGuidesCount-- > 1
                tokens.push({
                  screenExtent: @tabLength,
                  bufferExtent: Point.ZERO,
                  metadata: VOID | SOFT_WRAP_INDENTATION | SHOW_INDENT_GUIDE
                })

              tokens.push({
                screenExtent: (indentLength % @tabLength) or @tabLength,
                bufferExtent: Point.ZERO,
                metadata: VOID | SOFT_WRAP_INDENTATION | SHOW_INDENT_GUIDE
              })
            else
              tokens.push({
                screenExtent: indentLength,
                bufferExtent: Point.ZERO
                metadata: VOID | SOFT_WRAP_INDENTATION
              })
            tokensScreenExtent += indentLength
            screenColumn += indentLength
            screenLineWidth += @ratioForCharacter(' ') * indentLength

          if excessTokens?
            tokens.push(excessTokens...)
            tokensScreenExtent += excessTokensScreenExtent
            excessTokens = null
            excessTokensScreenExtent = 0

        if foldEndBufferPosition?
          if screenColumn > tokensScreenExtent
            behindCount = screenColumn - tokensScreenExtent
            tokens.push({
              screenExtent: behindCount,
              bufferExtent: Point(0, behindCount)
              metadata: 0
            })
            tokensScreenExtent = screenColumn

          previousPositionWasFold = true
          foldStartBufferPosition = Point(bufferRow, bufferColumn)
          tokens.push({
            screenExtent: 1,
            bufferExtent: traversal(foldEndBufferPosition, foldStartBufferPosition),
            metadata: FOLD | ATOMIC
          })

          bufferRow = foldEndBufferPosition.row
          bufferColumn = foldEndBufferPosition.column
          bufferLine = @buffer.lineForRow(bufferRow)
          bufferLineLength = bufferLine.length
          isEmptyLine &&= (bufferLineLength is 0)
          screenColumn += 1
          screenLineWidth += @ratioForCharacter(@foldCharacter)
          tokensScreenExtent = screenColumn
          wrapBoundaryBufferColumn = bufferColumn
          wrapBoundaryScreenColumn = screenColumn
          wrapBoundaryEndsLeadingWhitespace = false
          screenLineWidthAtWrapCharacter = screenLineWidth
          inLeadingWhitespace = true
          for column in [0...bufferColumn] by 1
            character = bufferLine[column]
            unless character is ' ' or character is '\t'
              inLeadingWhitespace = false
              break
          trailingWhitespaceStartBufferColumn = @findTrailingWhitespaceStartBufferColumn(bufferLine)
          if bufferColumn >= trailingWhitespaceStartBufferColumn
            trailingWhitespaceStartBufferColumn = bufferColumn
        else
          if character is '\t'
            if screenColumn > tokensScreenExtent
              behindCount = screenColumn - tokensScreenExtent
              tokens.push({
                screenExtent: behindCount,
                bufferExtent: Point(0, behindCount)
                metadata: 0
              })
              tokensScreenExtent = screenColumn

            distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
            metadata = HARD_TAB | ATOMIC
            metadata |= LEADING_WHITESPACE if inLeadingWhitespace
            metadata |= TRAILING_WHITESPACE if inTrailingWhitespace
            metadata |= INVISIBLE_CHARACTER if @invisibles.tab?
            metadata |= SHOW_INDENT_GUIDE if @showIndentGuides and (inLeadingWhitespace or isBlankLine and inTrailingWhitespace) and distanceToNextTabStop is @tabLength
            tokens.push({
              screenExtent: distanceToNextTabStop,
              bufferExtent: Point(0, 1),
              metadata
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
          metadata: 0
        })
        tokensScreenExtent = screenColumn

      if isEmptyLine
        emptyLineWhitespaceLength = @whitespaceLengthForEmptyBufferRow(bufferRow)
      else
        emptyLineWhitespaceLength = 0

      lineEnding = @buffer.lineEndingForRow(bufferRow)
      if eolInvisibleReplacement = @eolInvisibles[lineEnding]
        metadata = LINE_ENDING | VOID | INVISIBLE_CHARACTER
        metadata |= SHOW_INDENT_GUIDE if @showIndentGuides and emptyLineWhitespaceLength > 0
        if lineEnding is '\n'
          metadata |= LF
        else if lineEnding is '\r\n'
          metadata |= (CR | LF)
        else if lineEnding is '\r'
          metadata |= CR

        tokens.push({
          screenExtent: eolInvisibleReplacement.length,
          bufferExtent: Point(0, 0),
          metadata
        })
        screenColumn += eolInvisibleReplacement.length
        tokensScreenExtent = screenColumn
        emptyLineWhitespaceLength -= eolInvisibleReplacement.length

      while @showIndentGuides and emptyLineWhitespaceLength > 0 and not previousPositionWasFold
        distanceToNextTabStop = @tabLength - (screenColumn % @tabLength)
        screenExtent = Math.min(distanceToNextTabStop, emptyLineWhitespaceLength)
        metadata = VOID
        metadata |= SHOW_INDENT_GUIDE if (screenColumn % @tabLength is 0)
        tokens.push({
          screenExtent: screenExtent,
          bufferExtent: Point(0, 0),
          metadata
        })
        screenColumn += screenExtent
        tokensScreenExtent = screenColumn
        emptyLineWhitespaceLength -= screenExtent

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
        tokens,
        softWrappedAtStart: continuingSoftWrappedLine
        softWrappedAtEnd: false
      })
      tokens = []
      screenLineWidth = 0

    screenLines

  # Given a buffer row range, compute an index of all folds that appear on
  # screen lines containing this range. This may expand the initial buffer range
  # if the start row or end row appear on the same screen line as earlier or
  # later buffer lines due to folds.
  #
  # Returns an object containing the new startBufferRow and endBufferRow, along
  # with a folds object mapping startRow to startColumn to endPosition.
  computeFoldsInBufferRowRange: (startBufferRow, endBufferRow) ->
    folds = {}
    foldMarkers = @findFoldMarkers(intersectsRowRange: [startBufferRow, endBufferRow - 1], valid: true)
    if foldMarkers.length > 0
      # If the first fold starts before the initial row range, prepend any
      # fold markers that intersect the first fold's row range.
      loop
        foldsStartBufferRow = foldMarkers[0].getStartPosition().row
        break unless foldsStartBufferRow < startBufferRow
        precedingFoldMarkers = @findFoldMarkers(intersectsRowRange: [foldsStartBufferRow, startBufferRow - 1])
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
            followingFoldMarkers = @findFoldMarkers(intersectsRowRange: [endBufferRow, foldEnd.row])
            foldMarkers.push(followingFoldMarkers...)
            endBufferRow = foldEnd.row + 1

          # Skip subsequent fold markers that nest within the current
          # fold, and merge folds that start within the current fold but
          # end after it. Subsequent folds that start exactly where the
          # current fold ends will be preserved.
          if i < (foldMarkers.length - 1) and comparePoints(foldMarkers[i + 1].getStartPosition(), foldEnd) < 0
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

  whitespaceLengthForEmptyBufferRow: (bufferRow) ->
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
      maxLeadingWhitespace = Math.max(maxLeadingWhitespace, @findLeadingWhitespaceEndScreenColumn(previousLine))
    if nextLine?
      maxLeadingWhitespace = Math.max(maxLeadingWhitespace, @findLeadingWhitespaceEndScreenColumn(nextLine))

    maxLeadingWhitespace

  # Walk forward through the line, looking for the first non whitespace
  # character *and* expanding tabs as we go. If we return 0, this means
  # there is no leading whitespace.
  findLeadingWhitespaceEndScreenColumn: (line) ->
    screenExtent = 0
    for character in line by 1
      if character is '\t'
        screenExtent += @tabLength - (screenExtent % @tabLength)
      else if character is ' '
        screenExtent += 1
      else
        break
    screenExtent

  # Walk backwards through the line, looking for the first non
  # whitespace character. The trailing whitespace starts *after* that
  # character. If we return the line's length, this means there is no
  # trailing whitespace.
  findTrailingWhitespaceStartBufferColumn: (line) ->
    for character, column in line by -1
      unless character is ' ' or character is '\t'
        return column + 1
    0

  truncateTokens: (tokens, screenExtent, truncationScreenColumn) ->
    excessTokens = []
    while token = tokens.pop()
      tokenStart = screenExtent - token.screenExtent
      if tokenStart < truncationScreenColumn
        excess = truncationScreenColumn - tokenStart
        excessTokens.unshift({
          bufferExtent: Point(token.bufferExtent.row, token.bufferExtent.column - excess)
          screenExtent: token.screenExtent - excess
          metadata: token.metadata
        })

        token.screenExtent = excess
        token.bufferExtent.column = excess
        tokens.push(token)
      else
        excessTokens.unshift(token)

      break if tokenStart <= truncationScreenColumn
      screenExtent = tokenStart
    excessTokens

  getText: ->
    @getScreenLines().map((screenLine) -> screenLine.lineText).join('\n')

  getScreenLines: (startRow=0, endRow=@getScreenLineCount()) ->
    decorationIterator = @textDecorationLayer.buildIterator()
    screenLines = []
    @spatialLineIterator.seekToScreenRow(startRow)
    containingTags = decorationIterator.seek(@spatialLineIterator.getBufferStart())
    previousLineWasCached = false

    while @spatialLineIterator.getScreenRow() < endRow
      screenLineId = @spatialLineIterator.getId()
      if @screenLinesBySpatialLineId.has(screenLineId)
        screenLines.push(@screenLinesBySpatialLineId.get(screenLineId))
        previousLineWasCached = true
      else
        #### TODO: These are temporary, for investigating a bug
        wasCached = previousLineWasCached
        decorationIteratorPositionBeforeSeek = decorationIterator.getPosition()
        ####

        bufferStart = @spatialLineIterator.getBufferStart()
        if previousLineWasCached
          containingTags = decorationIterator.seek(bufferStart)
          previousLineWasCached = false
        screenLineText = ''
        tagCodes = []
        spatialDecoration = null
        closeTags = []
        openTags = containingTags.slice()
        atLineStart = true

        if comparePoints(decorationIterator.getPosition(), bufferStart) < 0
          iteratorPosition = decorationIterator.getPosition()
          error = new Error("Invalid text decoration iterator position")

          # Collect subset of tokenized line data on rows around to this error
          interestingBufferRows = new Set([Math.max(0, bufferStart.row - 3)..bufferStart.row].concat([Math.max(0, iteratorPosition.row - 3)..iteratorPosition.row]))
          interestingBufferRows.add(decorationIteratorPositionBeforeSeek.row)
          tokenizedLines = {}
          interestingBufferRows.forEach (row) =>
            if tokenizedLine = @textDecorationLayer?.tokenizedLineForRow?(row)
              {tags, openScopes} = tokenizedLine
              tokenizedLines[row] = {tags, openScopes}

          # Collect spatial screen lines on rows around to this error
          screenLines = @displayIndex.getScreenLines()
          spatialScreenLines = {}
          for screenRow in [Math.max(0, @spatialLineIterator.getScreenRow() - 3)..@spatialLineIterator.getScreenRow()]
            spatialScreenLines[screenRow] = screenLines[screenRow]

          error.metadata = {
            spatialLineBufferStart: Point.fromObject(bufferStart).toString(),
            decorationIteratorPosition: Point.fromObject(iteratorPosition).toString(),
            previousLineWasCached: wasCached,
            decorationIteratorPositionBeforeSeek: Point.fromObject(decorationIteratorPositionBeforeSeek).toString(),
            spatialScreenLines: spatialScreenLines,
            tokenizedLines: tokenizedLines,
            grammarScopeName: @textDecorationLayer.grammar?.scopeName,
            tabLength: @tabLength,
            invisibles: JSON.stringify(@invisibles),
            showIndentGuides: @showIndentGuides,
            softWrapColumn: @softWrapColumn,
            softWrapHangingIndent: @softWrapHangingIndent,
            foldCount: @foldsMarkerLayer.getMarkerCount(),
            atomicSoftTabs: @atomicSoftTabs
          }
          throw error

        for {screenExtent, bufferExtent, metadata} in @spatialLineIterator.getTokens()
          spatialTokenBufferEnd = traverse(bufferStart, bufferExtent)
          tagsToClose = []
          tagsToOpen = []

          if metadata & FOLD
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

            if not (metadata & SOFT_LINE_BREAK)
              if tagsToReopenAfterFold?
                tagsToOpen.push(tagsToReopenAfterFold...)
                tagsToReopenAfterFold = null

              if comparePoints(decorationIterator.getPosition(), bufferStart) is 0
                tagsToClose.push(decorationIterator.getCloseTags()...)
                tagsToOpen.push(decorationIterator.getOpenTags()...)
                decorationIterator.moveToSuccessor()

          if spatialDecoration = getSpatialTokenTextDecoration(metadata)
            tagsToOpen.push(spatialDecoration)

          @updateTags(closeTags, openTags, containingTags, tagsToClose, tagsToOpen, atLineStart)

          spatialTokenText = @buildTokenText(metadata, screenExtent, bufferStart, spatialTokenBufferEnd)
          startIndex = 0
          while comparePoints(decorationIterator.getPosition(), spatialTokenBufferEnd) < 0
            endIndex = startIndex + decorationIterator.getPosition().column - bufferStart.column
            tagCodes.push(@codeForCloseTag(tag)) for tag in closeTags
            tagCodes.push(@codeForOpenTag(tag)) for tag in openTags
            tagCodes.push(endIndex - startIndex)
            bufferStart = decorationIterator.getPosition()
            startIndex = endIndex
            closeTags = []
            openTags = []
            @updateTags(closeTags, openTags, containingTags, decorationIterator.getCloseTags(), decorationIterator.getOpenTags())
            decorationIterator.moveToSuccessor()

          tagCodes.push(@codeForCloseTag(tag)) for tag in closeTags
          tagCodes.push(@codeForOpenTag(tag)) for tag in openTags
          tagCodes.push(spatialTokenText.length - startIndex)

          screenLineText += spatialTokenText

          closeTags = []
          openTags = []
          bufferStart = spatialTokenBufferEnd
          atLineStart = false

        if containingTags.length > 0
          for containingTag in containingTags by -1
            tagCodes.push(@codeForCloseTag(containingTag))

        if tagsToReopenAfterFold?
          containingTags = tagsToReopenAfterFold
          tagsToReopenAfterFold = null
        else if spatialDecoration?
          containingTags.splice(containingTags.indexOf(spatialDecoration), 1)

        while not @spatialLineIterator.isSoftWrappedAtEnd() and comparePoints(decorationIterator.getPosition(), spatialTokenBufferEnd) is 0
          @updateTags(closeTags, openTags, containingTags, decorationIterator.getCloseTags(), decorationIterator.getOpenTags())
          decorationIterator.moveToSuccessor()

        invalidationCount = @invalidationCountsBySpatialLineId.get(screenLineId) ? 0
        screenLine = {id: "#{screenLineId}-#{invalidationCount}", lineText: screenLineText, tagCodes}
        @screenLinesBySpatialLineId.set(screenLineId, screenLine)
        screenLines.push(screenLine)

      break unless @spatialLineIterator.moveToSuccessor()
    screenLines

  isOpenTagCode: (tagCode) ->
    tagCode < 0 and tagCode % 2 is -1

  isCloseTagCode: (tagCode) ->
    tagCode < 0 and tagCode % 2 is 0

  tagForCode: (tagCode) ->
    tagCode++ if @isCloseTagCode(tagCode)
    @tagsByCode.get(tagCode)

  codeForOpenTag: (tag) ->
    if @codesByTag.has(tag)
      @codesByTag.get(tag)
    else
      codeForTag = @nextOpenTagCode
      @codesByTag.set(tag, @nextOpenTagCode)
      @tagsByCode.set(@nextOpenTagCode, tag)
      @nextOpenTagCode -= 2
      codeForTag

  codeForCloseTag: (tag) ->
    @codeForOpenTag(tag) - 1

  buildTokenText: (metadata, screenExtent, bufferStart, bufferEnd) ->
    if metadata & HARD_TAB
      if @invisibles.tab?
        @invisibles.tab + ' '.repeat(screenExtent - 1)
      else
        ' '.repeat(screenExtent)
    else if ((metadata & LEADING_WHITESPACE) or (metadata & TRAILING_WHITESPACE)) and @invisibles.space?
      @invisibles.space.repeat(screenExtent)
    else if metadata & FOLD
      @foldCharacter
    else if metadata & VOID
      if metadata & LINE_ENDING
        if (metadata & CR) and (metadata & LF)
          @eolInvisibles['\r\n']
        else if metadata & LF
          @eolInvisibles['\n']
        else
          @eolInvisibles['\r']
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
            tagsToCloseCounts[mostRecentOpenTag]--
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

  translateBufferPosition: (bufferPosition, options) ->
    bufferPosition = @buffer.clipPosition(bufferPosition, options)
    clipDirection = options?.clipDirection

    @spatialTokenIterator.seekToBufferPosition(bufferPosition)

    if @spatialTokenIterator.getMetadata() & SOFT_LINE_BREAK or @spatialTokenIterator.getMetadata() & SOFT_WRAP_INDENTATION
      clipDirection = 'forward'

    while @spatialTokenIterator.getMetadata() & VOID
      if clipDirection is 'forward'
        if @spatialTokenIterator.moveToSuccessor()
          bufferPosition = @spatialTokenIterator.getBufferStart()
        else
          clipDirection = 'backward'
      else
        @spatialTokenIterator.moveToPredecessor()
        bufferPosition = @spatialTokenIterator.getBufferEnd()

    if @spatialTokenIterator.getMetadata() & ATOMIC
      if comparePoints(bufferPosition, @spatialTokenIterator.getBufferStart()) is 0
        screenPosition = @spatialTokenIterator.getScreenStart()
      else if comparePoints(bufferPosition, @spatialTokenIterator.getBufferEnd()) is 0 or options?.clipDirection is 'forward'
        screenPosition = @spatialTokenIterator.getScreenEnd()
      else if options?.clipDirection is 'backward'
        screenPosition = @spatialTokenIterator.getScreenStart()
      else # clipDirection is 'closest'
        distanceFromStart = traversal(bufferPosition, @spatialTokenIterator.getBufferStart())
        distanceFromEnd = traversal(@spatialTokenIterator.getBufferEnd(), bufferPosition)
        if distanceFromEnd.compare(distanceFromStart) < 0
          screenPosition = @spatialTokenIterator.getScreenEnd()
        else
          screenPosition = @spatialTokenIterator.getScreenStart()
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

    while @spatialTokenIterator.getMetadata() & VOID
      if @spatialTokenIterator.getMetadata() & LINE_ENDING and comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        break

      if (clipDirection is 'forward' or
          (options?.skipSoftWrapIndentation and @spatialTokenIterator.getMetadata() & SOFT_WRAP_INDENTATION))
        if @spatialTokenIterator.moveToSuccessor()
          screenPosition = @spatialTokenIterator.getScreenStart()
        else
          clipDirection = 'backward'
      else
        softLineBreak = @spatialTokenIterator.getMetadata() & SOFT_LINE_BREAK
        @spatialTokenIterator.moveToPredecessor()
        screenPosition = @spatialTokenIterator.getScreenEnd()
        screenPosition = traverse(screenPosition, Point(0, -1)) if softLineBreak

    if @spatialTokenIterator.getMetadata() & ATOMIC
      if comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        bufferPosition = @spatialTokenIterator.getBufferStart()
      else if comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) is 0 or options?.clipDirection is 'forward'
        bufferPosition = @spatialTokenIterator.getBufferEnd()
      else if options?.clipDirection is 'backward'
        bufferPosition = @spatialTokenIterator.getBufferStart()
      else # clipDirection is 'closest'
        screenStartColumn = @spatialTokenIterator.getScreenStart().column
        screenEndColumn = @spatialTokenIterator.getScreenEnd().column
        if screenPosition.column > ((screenStartColumn + screenEndColumn) / 2)
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

    while @spatialTokenIterator.getMetadata() & VOID
      if @spatialTokenIterator.getMetadata() & LINE_ENDING and comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) is 0
        break

      if (clipDirection is 'forward' or
          (options?.skipSoftWrapIndentation and @spatialTokenIterator.getMetadata() & SOFT_WRAP_INDENTATION))
        if @spatialTokenIterator.moveToSuccessor()
          screenPosition = @spatialTokenIterator.getScreenStart()
        else
          clipDirection = 'backward'
      else
        softLineBreak = @spatialTokenIterator.getMetadata() & SOFT_LINE_BREAK
        @spatialTokenIterator.moveToPredecessor()
        screenPosition = @spatialTokenIterator.getScreenEnd()
        screenPosition = traverse(screenPosition, Point(0, -1)) if softLineBreak

    if comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) <= 0
      if (@spatialTokenIterator.getMetadata() & ATOMIC and
          comparePoints(screenPosition, @spatialTokenIterator.getScreenStart()) > 0 and
          comparePoints(screenPosition, @spatialTokenIterator.getScreenEnd()) < 0)
        if options?.clipDirection is 'forward'
          screenPosition = @spatialTokenIterator.getScreenEnd()
        else if options?.clipDirection is 'backward'
          screenPosition = @spatialTokenIterator.getScreenStart()
        else # clipDirection is 'closest'
          screenStartColumn = @spatialTokenIterator.getScreenStart().column
          screenEndColumn = @spatialTokenIterator.getScreenEnd().column
          if screenPosition.column > ((screenStartColumn + screenEndColumn) / 2)
            screenPosition = @spatialTokenIterator.getScreenEnd()
          else
            screenPosition = @spatialTokenIterator.getScreenStart()
    else
      if options?.clipDirection is 'forward' and @spatialTokenIterator.moveToSuccessor()
        screenPosition = @spatialTokenIterator.getScreenStart()
      else
        screenPosition = @spatialTokenIterator.getScreenEnd()

    Point.fromObject(screenPosition)

  softWrapDescriptorForScreenRow: (row) ->
    @spatialLineIterator.seekToScreenRow(row)
    {
      softWrappedAtStart: @spatialLineIterator.isSoftWrappedAtStart(),
      softWrappedAtEnd: @spatialLineIterator.isSoftWrappedAtEnd(),
      bufferRow: @spatialLineIterator.getBufferStart().row
    }

  getScreenLineCount: ->
    @displayIndex.getScreenLineCount()

  getRightmostScreenPosition: ->
    @displayIndex.getScreenPositionWithMaxLineLength() or Point.ZERO

  lineLengthForScreenRow: (screenRow) ->
    @displayIndex.lineLengthForScreenRow(screenRow) or 0
