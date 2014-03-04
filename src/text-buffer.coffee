_ = require 'underscore-plus'
Delegator = require 'delegato'
Serializable = require 'serializable'
{Emitter, Subscriber} = require 'emissary'
{File} = require 'pathwatcher'
SpanSkipList = require 'span-skip-list'
diff = require 'diff'
Q = require 'q'
Point = require './point'
Range = require './range'
History = require './history'
MarkerManager = require './marker-manager'
BufferPatch = require './buffer-patch'
{spliceArray} = require './helpers'

# Public: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
module.exports =
class TextBuffer
  @Point: Point
  @Range: Range

  Delegator.includeInto(this)
  Emitter.includeInto(this)
  Serializable.includeInto(this)
  Subscriber.includeInto(this)

  @delegatesMethods 'undo', 'redo', 'transact', 'beginTransaction', 'commitTransaction',
    'abortTransaction', 'isTransacting', 'clearUndoStack', toProperty: 'history'

  @delegatesMethods 'markRange', 'markPosition', 'getMarker', 'getMarkers',
    'findMarkers', 'getMarkerCount', toProperty: 'markers'

  cachedText: null
  stoppedChangingDelay: 300
  stoppedChangingTimeout: null
  cachedDiskContents: null
  conflict: false
  file: null
  refcount: 0

  # Public: Create a new buffer with the given params.
  #
  # params - A {String} of text or an {Object} with the following keys:
  #   :load - A {Boolean}, `true` to asynchronously load the buffer from disk
  #           after initialization.
  #   :text - The initial {String} text of the buffer.
  constructor: (params) ->
    text = params if typeof params is 'string'

    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', false)
    @history = params?.history ? new History(this)
    @markers = params?.markers ? new MarkerManager(this)

    @loaded = false
    @digestWhenLastPersisted = params?.digestWhenLastPersisted ? false
    @modifiedWhenLastPersisted = params?.modifiedWhenLastPersisted ? false
    @useSerializedText = @modifiedWhenLastPersisted isnt false
    @subscribe this, 'changed', @handleTextChange

    @setPath(params.filePath) if params?.filePath
    @load() if params?.load

  # Called by {Serializable} mixin during deserialization.
  deserializeParams: (params) ->
    params.markers = MarkerManager.deserialize(params.markers, buffer: this)
    params.history = History.deserialize(params.history, buffer: this)
    params.load = true
    params

  # Called by {Serializable} mixin during serialization.
  serializeParams: ->
    text: @getText()
    markers: @markers.serialize()
    history: @history.serialize()
    filePath: @getPath()
    modifiedWhenLastPersisted: @isModified()
    digestWhenLastPersisted: @file?.getDigest()

  # Public: Returns a {String} representing the entire contents of the buffer.
  getText: ->
    if @cachedText?
      @cachedText
    else
      text = ''
      for row in [0..@getLastRow()]
        text += (@lineForRow(row) + @lineEndingForRow(row))
      @cachedText = text

  # Public: Returns an {Array} of {String}s representing all the lines in the
  # buffer, without line endings.
  getLines: ->
    @lines.slice()

  # Public: Returns a {Boolean}, `true` if this buffer has no text, `false`
  # otherwise.
  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

  # Public: Returns a {Number} representing the number of lines in the buffer.
  getLineCount: ->
    @lines.length

  # Public: Returns a {Number} representing the last zero-indexed row number of
  # the buffer.
  getLastRow: ->
    @getLineCount() - 1

  # Public: Returns a {String} representing the contents of the line at the
  # given row.
  #
  # row - A {Number} representing a zero-indexed row.
  lineForRow: (row) ->
    @lines[row]

  # Public: Returns a {String} representing the last line of the buffer
  getLastLine: ->
    @lineForRow(@getLastRow())

  # Public: Returns a {String} representing the line ending for the given row.
  #
  # row - A {Number} indicating the row.
  #
  # Returns '\n', '\r\n', or '' for the last line of the buffer.
  lineEndingForRow: (row) ->
    @lineEndings[row]

  # Public: Returns a {Number} representing the line length for the given row,
  # exclusive of its line-ending character(s).
  #
  # row - A {Number} indicating the row.
  lineLengthForRow: (row) ->
    @lines[row].length

  # Public: Replaces the entire contents of the buffer with the given {String}
  setText: (text) ->
    @setTextInRange(@getRange(), text, false)

  # Public: Replaces the current buffer contents by applying a diff against
  # the given contents.
  #
  # text - A {String} containing the new buffer contents.
  setTextViaDiff: (text) ->
    currentText = @getText()
    return if currentText == text

    endsWithNewline = (str) ->
      /[\r\n]+$/g.test(str)

    computeBufferColumn = (str) ->
      newlineIndex = Math.max(str.lastIndexOf('\n'), str.lastIndexOf('\r'))
      if endsWithNewline(str)
        0
      else if newlineIndex == -1
        str.length
      else
        str.length - newlineIndex - 1

    @transact =>
      row = 0
      column = 0
      currentPosition = [0, 0]

      lineDiff = diff.diffLines(currentText, text)
      changeOptions = normalizeLineEndings: false

      for change in lineDiff
        lineCount = change.value.match(/\n/g)?.length ? 0
        currentPosition[0] = row
        currentPosition[1] = column

        if change.added
          @setTextInRange([currentPosition, currentPosition], change.value, changeOptions)
          row += lineCount
          column = computeBufferColumn(change.value)

        else if change.removed
          endRow = row + lineCount
          endColumn = column + computeBufferColumn(change.value)
          @setTextInRange([currentPosition, [endRow, endColumn]], '', changeOptions)

        else
          row += lineCount
          column = computeBufferColumn(change.value)

  # Public: Sets the text in the given range.
  #
  # range - A {Range}.
  # text - A {String}.
  #
  # Returns the {Range} of the inserted text.
  setTextInRange: (range, text, normalizeLineEndings=true) ->
    patch = @buildPatch(range, text, normalizeLineEndings)
    @history?.recordNewPatch(patch)
    @applyPatch(patch)
    patch.newRange

  # Public: Inserts the given text at the given position
  #
  # position - A {Point} representing the insertion location. The position is
  #            clipped before insertion.
  # text - A {String} representing the text to insert.
  #
  # Returns the {Range} of the inserted text
  insert: (position, text, normalizeLineEndings) ->
    @setTextInRange(new Range(position, position), text, normalizeLineEndings)

  # Public: Appends the given text to the end of the buffer
  #
  # text - A {String} representing the text text to append.
  #
  # Returns the {Range} of the inserted text
  append: (text, normalizeLineEndings) ->
    @insert(@getEndPosition(), text, normalizeLineEndings)

  # Public: Deletes the text in the given range
  #
  # range - A {Range} in which to delete. The range is clipped before deleting.
  #
  # Returns an empty {Range} starting at the start of deleted range.
  delete: (range) ->
    @setTextInRange(range, '')

  # Public: Deletes the line associated with the specified row.
  #
  # Returns the {Range} of the deleted text.
  deleteRow: (row) ->
    @deleteRows(row, row)

  # Public: Deletes the specified lines associated with the specified row range.
  # If the row range is out of bounds, it will be clipped. If the startRow is
  # greater than the end row, they will be reordered.
  #
  # Returns the {Range} of the deleted text.
  deleteRows: (startRow, endRow) ->
    lastRow = @getLastRow()

    [startRow, endRow] = [endRow, startRow] if startRow > endRow

    if endRow < 0
      return new Range(@getFirstPosition(), @getFirstPosition())

    if startRow > lastRow
      return new Range(@getEndPosition(), @getEndPosition())

    startRow = Math.max(0, startRow)
    endRow = Math.min(lastRow, endRow)

    if endRow < lastRow
      startPoint = new Point(startRow, 0)
      endPoint = new Point(endRow + 1, 0)
    else
      if startRow is 0
        startPoint = new Point(startRow, 0)
      else
        startPoint = new Point(startRow - 1, @lineLengthForRow(startRow - 1))
      endPoint = new Point(endRow, @lineLengthForRow(endRow))

    @delete(new Range(startPoint, endPoint))

  # Builds a {BufferPatch}, which is used to modify the buffer and is also
  # pushed into the undo history so it can be undone.
  buildPatch: (oldRange, newText, normalizeLineEndings) ->
    oldRange = @clipRange(oldRange)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    patch = new BufferPatch(oldRange, newRange, oldText, newText, normalizeLineEndings)
    @markers?.handleBufferChange(patch)
    patch

  # Applies a {BufferPatch} to the buffer based on its old range and new text.
  # Also applies any {MarkerPatch}es associated with the {BufferPatch}.
  applyPatch: ({oldRange, newRange, oldText, newText, normalizeLineEndings, markerPatches}) ->
    @cachedText = null

    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    # Determine how to normalize the line endings of inserted text if enabled
    if normalizeLineEndings
      normalizedEnding = @lineEndingForRow(startRow)
      if normalizedEnding is ''
        if startRow > 0
          normalizedEnding = @lineEndingForRow(startRow - 1)
        else
          normalizedEnding = null

    # Split inserted text into lines and line endings
    lines = newText.split('\n')
    lineEndings = []
    for line, index in lines
      if line[-1..] is '\r'
        lines[index] = line[0...-1]
        lineEndings.push(normalizedEnding ? '\r\n')
      else
        lineEndings.push(normalizedEnding ? '\n')

    # Update first and last line so replacement preserves existing prefix and suffix of oldRange
    lastIndex = lines.length - 1
    prefix = @lineForRow(startRow)[0...oldRange.start.column]
    suffix = @lineForRow(endRow)[oldRange.end.column...]
    lines[0] = prefix + lines[0]
    lines[lastIndex] += suffix
    lastLineEnding = @lineEndingForRow(endRow)
    lastLineEnding = normalizedEnding if lastLineEnding isnt '' and normalizedEnding?
    lineEndings[lastIndex] = lastLineEnding

    # Replace lines in oldRange with new lines
    spliceArray(@lines, startRow, rowCount, lines)
    spliceArray(@lineEndings, startRow, rowCount, lineEndings)

    # Update the offset index for position <-> character offset translation
    offsets = lines.map (line, index) ->
      {rows: 1, characters: line.length + lineEndings[index].length}
    @offsetIndex.spliceArray('rows', startRow, rowCount, offsets)

    @markers?.pauseChangeEvents()
    @markers?.applyPatches(markerPatches, true)
    @emit 'changed', {oldRange, newRange, oldText, newText}
    @markers?.resumeChangeEvents()
    @emit 'markers-updated'

  # Public: Returns a {String} of text in the given {Range}.
  getTextInRange: (range) ->
    range = @clipRange(Range.fromObject(range))
    startRow = range.start.row
    endRow = range.end.row

    if startRow is endRow
      @lineForRow(startRow)[range.start.column...range.end.column]
    else
      text = ''
      for row in [startRow..endRow]
        line = @lineForRow(row)
        if row is startRow
          text += line[range.start.column...]
        else if row is endRow
          text += line[0...range.end.column]
          continue
        else
          text += line
        text += @lineEndingForRow(row)
      text

  # Public: Clips the given range so it starts and ends at valid positions if
  # its start or end are out of bounds. For example, the position [1, 100] is
  # out of bounds if the line at row 1 is only 10 characters long, and it would
  # be clipped to (1, 10).
  #
  # range - A {Range} to clip.
  #
  # Returns the given {Range} if it is already in bounds, or a new clipped
  # {Range} if the given range is out-of-bounds.
  clipRange: (range) ->
    range = Range.fromObject(range)
    start = @clipPosition(range.start)
    end = @clipPosition(range.end)
    if range.start.isEqual(start) and range.end.isEqual(end)
      range
    else
      new Range(start, end)

  # Public: Clips the given point so it is at a valid position in the buffer.
  # For example, the position (1, 100) is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to (1, 10)
  clipPosition: (position) ->
    position = Point.fromObject(position)
    {row, column} = position
    if row < 0
      @getFirstPosition()
    else if row > @getLastRow()
      @getEndPosition()
    else
      column = Math.min(Math.max(column, 0), @lineLengthForRow(row))
      if column is position.column
        position
      else
        new Point(row, column)

  # Public: Returns a {Point} at [0, 0]
  getFirstPosition: ->
    new Point(0, 0)

  # Public: Returns a {Point} representing the maximal position in the buffer.
  getEndPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  # Public: Returns a {Range} associated with the text of the entire buffer,
  # from its first position to its last position.
  getRange: ->
    new Range(@getFirstPosition(), @getEndPosition())

  # Public: Returns the range for the given row
  #
  # row - A row {Number}.
  # includeNewline - Whether or not to include the newline, resulting in a range
  #                  that extends to the start of the next line.
  #
  # Returns a {Range}.
  rangeForRow: (row, includeNewline) ->
    # Handle deprecated options hash
    if typeof includeNewline is 'object'
      {includeNewline} = includeNewline

    if includeNewline and row < @getLastRow()
      new Range(new Point(row, 0), new Point(row + 1, 0))
    else
      new Range(new Point(row, 0), new Point(row, @lineLengthForRow(row)))

  # Public: Given a {Point} representing a position in the buffer, returns a
  # {Number} representing the absolute character offset of that location in the
  # buffer, inclusive of newlines. The position is clipped prior to translating.
  characterIndexForPosition: (position) ->
    {row, column} = @clipPosition(Point.fromObject(position))

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  # Public: Given a {Number} represting an absolute offset in the buffer,
  # inclusive of newlines, returns a {Point} representing that numbers
  # corresponding position in row/column coordinates. The offset is clipped
  # prior to translating.
  positionForCharacterIndex: (offset) ->
    offset = Math.max(0, offset)
    offset = Math.min(@getMaxCharacterIndex(), offset)

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getEndPosition()
    else
      new Point(rows, offset - characters)

  # Public: Returns the length of the buffer in characters.
  getMaxCharacterIndex: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters

  loadSync: ->
    @updateCachedDiskContentsSync()
    @finishLoading()

  load: ->
    @updateCachedDiskContents().then => @finishLoading()

  finishLoading: ->
    if @isAlive()
      @loaded = true
      if @useSerializedText and @digestWhenLastPersisted is @file?.getDigest()
        @emitModifiedStatusChanged(true)
      else
        @reload()
      @clearUndoStack()
    this

  handleTextChange: (event) =>
    @conflict = false if @conflict and !@isModified()
    @scheduleModifiedEvents()

  destroy: ->
    unless @destroyed
      @cancelStoppedChangingTimeout()
      @file?.off()
      @unsubscribe()
      @destroyed = true
      @emit 'destroyed'

  isAlive: -> not @destroyed

  isDestroyed: -> @destroyed

  isRetained: -> @refcount > 0

  retain: ->
    @refcount++
    this

  release: ->
    @refcount--
    @destroy() unless @isRetained()
    this

  subscribeToFile: ->
    @file.on "contents-changed", =>
      @conflict = true if @isModified()
      previousContents = @cachedDiskContents

      # Synchrounously update the disk contents because the {File} has already cached them. If the
      # contents updated asynchrounously multiple `conlict` events could trigger for the same disk
      # contents.
      @updateCachedDiskContentsSync()
      return if previousContents == @cachedDiskContents

      if @conflict
        @emit "contents-conflicted"
      else
        @reload()

    @file.on "removed", =>
      modified = @getText() != @cachedDiskContents
      @wasModifiedBeforeRemove = modified
      if modified
        @updateCachedDiskContents()
      else
        @destroy()

    @file.on "moved", =>
      @emit "path-changed", this

  # Identifies if the buffer belongs to multiple editors.
  #
  # For example, if the {EditorView} was split.
  #
  # Returns a {Boolean}.
  hasMultipleEditors: -> @refcount > 1

  # Reloads a file in the {Editor}.
  #
  # Sets the buffer's content to the cached disk contents
  reload: ->
    @emit 'will-reload'
    @setTextViaDiff(@cachedDiskContents)
    @emitModifiedStatusChanged(false)
    @emit 'reloaded'

  # Rereads the contents of the file, and stores them in the cache.
  updateCachedDiskContentsSync: ->
    @cachedDiskContents = @file?.readSync() ? ""

  # Rereads the contents of the file, and stores them in the cache.
  updateCachedDiskContents: ->
    Q(@file?.read() ? "").then (contents) =>
      @cachedDiskContents = contents

  # Gets the file's basename--that is, the file without any directory information.
  #
  # Returns a {String}.
  getBaseName: ->
    @file?.getBaseName()

  # Retrieves the path for the file.
  #
  # Returns a {String}.
  getPath: ->
    @file?.getPath()

  getUri: ->
    @getPath()

  # Sets the path for the file.
  #
  # filePath - A {String} representing the new file path
  setPath: (filePath) ->
    return if filePath == @getPath()

    @file?.off()

    if filePath
      @file = new File(filePath)
      @subscribeToFile()
    else
      @file = null

    @emit "path-changed", this

  # Deprecated: Use ::getEndPosition instead
  getEofPosition: -> @getEndPosition()

  # Saves the buffer.
  save: ->
    @saveAs(@getPath()) if @isModified()

  # Saves the buffer at a specific path.
  #
  # filePath - The path to save at.
  saveAs: (filePath) ->
    unless filePath then throw new Error("Can't save buffer with no file path")

    @emit 'will-be-saved', this
    @setPath(filePath)
    @file.write(@getText())
    @cachedDiskContents = @getText()
    @conflict = false
    @emitModifiedStatusChanged(false)
    @emit 'saved', this

  # Public: Determine if the in-memory contents of the buffer differ from its
  # contents on disk.
  #
  # If the buffer is unsaved, always returns `true` unless the buffer is empty.
  #
  # Returns a {Boolean}.
  isModified: ->
    return false unless @loaded
    if @file
      if @file.exists()
        @getText() != @cachedDiskContents
      else
        @wasModifiedBeforeRemove ? not @isEmpty()
    else
      not @isEmpty()

  # Is the buffer's text in conflict with the text on disk?
  #
  # This occurs when the buffer's file changes on disk while the buffer has
  # unsaved changes.
  #
  # Returns a {Boolean}.
  isInConflict: -> @conflict

  destroyMarker: (id) ->
    @getMarker(id)?.destroy()

  # Identifies if a character sequence is within a certain range.
  #
  # regex - The {RegExp} to check.
  # startIndex - The starting row {Number}.
  # endIndex - The ending row {Number}.
  #
  # Returns an {Array} of {RegExp}s, representing the matches.
  matchesInCharacterRange: (regex, startIndex, endIndex) ->
    text = @getText()
    matches = []

    regex.lastIndex = startIndex
    while match = regex.exec(text)
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      if matchEndIndex > endIndex
        regex.lastIndex = 0
        if matchStartIndex < endIndex and submatch = regex.exec(text[matchStartIndex...endIndex])
          submatch.index = matchStartIndex
          matches.push submatch
        break

      matchEndIndex++ if matchLength is 0
      regex.lastIndex = matchEndIndex
      matches.push match

    matches

  # Scans for text in the buffer, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find.
  # iterator - A {Function} that's called on each match.
  scan: (regex, iterator) ->
    @scanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Scans for text in the buffer _backwards_, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find.
  # iterator - A {Function} that's called on each match.
  backwardsScan: (regex, iterator) ->
    @backwardsScanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Replace all matches of regex with replacementText
  #
  # regex - A {RegExp} representing the text to find.
  # replacementText - A {String} representing the text to replace.
  #
  # Returns the number of replacements made
  replace: (regex, replacementText) ->
    doSave = !@isModified()
    replacements = 0

    @transact =>
      @scan regex, ({matchText, replace}) ->
        replace(matchText.replace(regex, replacementText))
        replacements++

    @save() if doSave

    replacements

  # Scans for text in a given range, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find.
  # range - A {Range} in the buffer to search within.
  # iterator - A {Function} that's called on each match.
  # reverse - A {Boolean} indicating if the search should be backwards
  #           (default: `false`).
  scanInRange: (regex, range, iterator, reverse=false) ->
    range = @clipRange(range)
    global = regex.global
    flags = "gm"
    flags += "i" if regex.ignoreCase
    regex = new RegExp(regex.source, flags)

    startIndex = @characterIndexForPosition(range.start)
    endIndex = @characterIndexForPosition(range.end)

    matches = @matchesInCharacterRange(regex, startIndex, endIndex)
    lengthDelta = 0

    keepLooping = null
    replacementText = null
    stop = -> keepLooping = false
    replace = (text) -> replacementText = text

    matches.reverse() if reverse
    for match in matches
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      startPosition = @positionForCharacterIndex(matchStartIndex + lengthDelta)
      endPosition = @positionForCharacterIndex(matchEndIndex + lengthDelta)
      range = new Range(startPosition, endPosition)
      keepLooping = true
      replacementText = null
      matchText = match[0]
      iterator({ match, matchText, range, stop, replace })

      if replacementText?
        @change(range, replacementText)
        lengthDelta += replacementText.length - matchLength unless reverse

      break unless global and keepLooping

  # Scans for text in a given range _backwards_, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find.
  # range - A {Range} in the buffer to search within.
  # iterator - A {Function} that's called on each match.
  backwardsScanInRange: (regex, range, iterator) ->
    @scanInRange regex, range, iterator, true

  # Given a row, identifies if it is blank.
  #
  # row - A row {Number} to check.
  #
  # Returns a {Boolean}.
  isRowBlank: (row) ->
    not /\S/.test @lineForRow(row)

  # Given a row, this finds the next row above it that's empty.
  #
  # startRow - A {Number} identifying the row to start checking at.
  #
  # Returns the row {Number} of the first blank row or `null` if there's no
  #   other blank row.
  previousNonBlankRow: (startRow) ->
    return null if startRow == 0

    startRow = Math.min(startRow, @getLastRow())
    for row in [(startRow - 1)..0]
      return row unless @isRowBlank(row)
    null

  # Given a row, this finds the next row that's blank.
  #
  # startRow - A row {Number} to check
  #
  # Returns the row {Number} of the next blank row or `null` if there's no other
  #   blank row.
  nextNonBlankRow: (startRow) ->
    lastRow = @getLastRow()
    if startRow < lastRow
      for row in [(startRow + 1)..lastRow]
        return row unless @isRowBlank(row)
    null

  # Identifies if the buffer has soft tabs anywhere.
  #
  # Returns a {Boolean},
  usesSoftTabs: ->
    for row in [0..@getLastRow()]
      if match = @lineForRow(row).match(/^\s/)
        return match[0][0] != '\t'
    undefined

  change: (oldRange, newText, options={}) ->
    @setTextInRange(oldRange, newText, options.normalizeLineEndings)

  cancelStoppedChangingTimeout: ->
    clearTimeout(@stoppedChangingTimeout) if @stoppedChangingTimeout

  scheduleModifiedEvents: ->
    @cancelStoppedChangingTimeout()
    stoppedChangingCallback = =>
      @stoppedChangingTimeout = null
      modifiedStatus = @isModified()
      @emit 'contents-modified', modifiedStatus
      @emitModifiedStatusChanged(modifiedStatus)
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  emitModifiedStatusChanged: (modifiedStatus) ->
    return if modifiedStatus is @previousModifiedStatus
    @previousModifiedStatus = modifiedStatus
    @emit 'modified-status-changed', modifiedStatus

  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row)
      console.log row, line, line.length
