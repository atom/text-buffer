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
#
# ## Events
#
# * `changed` -
#      Emitted synchronously whenever the buffer changes. Binding a slow handler
#      to this event has the potential to destroy typing performance. Consider
#      using `contents-modified` instead and aim for extremely fast performance
#      (< 2 ms) if you must bind to it. Your handler will be called with an
#      object containing the following keys.
#      * `oldRange` - The {Range} of the old text
#      * `newRange` - The {Range} of the new text
#      * `oldText` - A {String} containing the text that was replaced
#      * `newText` - A {String} containing the text that was inserted
#
# * `markers-updated` -
#      Emitted synchronously when the `changed` events of all markers have been
#      fired for a change. The order of events is as follows:
#      * The text of the buffer is changed
#      * All markers are updated accordingly, but their `changed` events are not
#        emited
#      * The `changed` event is emitted
#      * The `changed` events of all updated markers are emitted
#      * The `markers-updated` event is emitted.
#
# * `contents-modified` -
#      Emitted asynchronously 300ms (or `TextBuffer::stoppedChangingDelay`)
#      after the last buffer change. This is a good place to handle changes to
#      the buffer without compromising typing performance.
#
# * `modified-status-changed` -
#      Emitted with a {Boolean} when the result of {::isModified} changes.
#
# * `contents-conflicted` -
#      Emitted when the buffer's underlying file changes on disk at a moment
#      when the result of {::isModified} is true.
#
# * `will-reload` -
#      Emitted before the in-memory contents of the buffer are refreshed from
#      the contents of the file on disk.
#
# * `reloaded` -
#      Emitted after the in-memory contents of the buffer are refreshed from
#      the contents of the file on disk.
#
# * `will-be-saved` - Emitted before the buffer is saved to disk.
#
# * `saved` - Emitted after the buffer is saved to disk.
#
# * `destroyed` - Emitted when the buffer is destroyed.
module.exports =
class TextBuffer
  @Point: Point
  @Range: Range

  Delegator.includeInto(this)
  Emitter.includeInto(this)
  Serializable.includeInto(this)
  Subscriber.includeInto(this)

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

  # Public: Get the entire text of the buffer.
  #
  # Returns a {String}.
  getText: ->
    if @cachedText?
      @cachedText
    else
      text = ''
      for row in [0..@getLastRow()]
        text += (@lineForRow(row) + @lineEndingForRow(row))
      @cachedText = text

  # Public: Get the text of all lines in the buffer, without their line endings.
  #
  # Returns an {Array} of {String}s.
  getLines: ->
    @lines.slice()

  # Public: Determine whether the buffer is empty.
  #
  # Returns a {Boolean}.
  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

  # Public: Get the number of lines in the buffer.
  #
  # Returns a {Number}.
  getLineCount: ->
    @lines.length

  # Public: Get the last 0-indexed row in the buffer.
  #
  # Returns a {Number}.
  getLastRow: ->
    @getLineCount() - 1

  # Public: Get the text of the line at the given row, without its line ending.
  #
  # row - A {Number} representing a 0-indexed row.
  #
  # Returns a {String}.
  lineForRow: (row) ->
    @lines[row]

  # Public: Get the text of the last line of the buffer, without its line
  # ending.
  #
  # Returns a {String}.
  getLastLine: ->
    @lineForRow(@getLastRow())

  # Public: Get the line ending for the given 0-indexed row.
  #
  # row - A {Number} indicating the row.
  #
  # The returned newline is represented as a literal string: `'\n'`, `'\r\n'`,
  # or `''` for the last line of the buffer, which doesn't end in a newline.
  #
  # Returns a {String}.
  lineEndingForRow: (row) ->
    @lineEndings[row]

  # Public: Get the length of the line for the given 0-indexed row, without its
  # line ending.
  #
  # row - A {Number} indicating the row.
  #
  # Returns a {Number}.
  lineLengthForRow: (row) ->
    @lines[row].length

  # Public: Replace the entire contents of the buffer with the given text.
  #
  # text - A {String}
  #
  # Returns a {Range} spanning the new buffer contents.
  setText: (text) ->
    @setTextInRange(@getRange(), text, false)

  # Public: Replace the current buffer contents by applying a diff based on the
  # given text.
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

  # Public: Set the text in the given range.
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

  # Public: Insert text at the given position.
  #
  # position - A {Point} representing the insertion location. The position is
  #            clipped before insertion.
  # text - A {String} representing the text to insert.
  #
  # Returns the {Range} of the inserted text.
  insert: (position, text, normalizeLineEndings) ->
    @setTextInRange(new Range(position, position), text, normalizeLineEndings)

  # Public: Append text to the end of the buffer.
  #
  # text - A {String} representing the text text to append.
  #
  # Returns the {Range} of the inserted text
  append: (text, normalizeLineEndings) ->
    @insert(@getEndPosition(), text, normalizeLineEndings)

  # Public: Delete the text in the given range.
  #
  # range - A {Range} in which to delete. The range is clipped before deleting.
  #
  # Returns an empty {Range} starting at the start of deleted range.
  delete: (range) ->
    @setTextInRange(range, '')

  # Public: Delete the line associated with a specified row.
  #
  # row - A {Number} representing the 0-indexed row to delete.
  #
  # Returns the {Range} of the deleted text.
  deleteRow: (row) ->
    @deleteRows(row, row)

  # Public: Delete the lines associated with the specified row range.
  #
  # startRow - A {Number} representing the first row to delete.
  # endRow - A {Number} representing the last row to delete, inclusive.
  #
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

  # Public: Get the text in a range.
  #
  # range - A {Range}
  #
  # Returns a {String}
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

  # Public: Clip the given range so it starts and ends at valid positions.
  #
  # For example, the position [1, 100] is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to (1, 10).
  #
  # range - A {Range} or range-compatible {Array} to clip.
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

  # Public: Clip the given point so it is at a valid position in the buffer.
  #
  # For example, the position (1, 100) is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to (1, 10)
  #
  # position - A {Point} or point-compatible {Array}.
  #
  # Returns a new {Point} if the given position is invalid, otherwise returns
  # the given position.
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

  # Public: Get the first position in the buffer, which is always `[0, 0]`.
  #
  # Returns a {Point}.
  getFirstPosition: ->
    new Point(0, 0)

  # Public: Get the maximal position in the buffer, where new text would be
  # appended.
  #
  # Returns a {Point}.
  getEndPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  # Public: Get the range spanning from `[0, 0]` to {::getEndPosition}.
  #
  # Returns a {Range}.
  getRange: ->
    new Range(@getFirstPosition(), @getEndPosition())

  # Public: Get the range for the given row
  #
  # row - A {Number} representing a 0-indexed row.
  # includeNewline - A {Boolean} indicating whether or not to include the
  #                  newline, which results in a range that extends to the start
  #                  of the next line.
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

  # Public: Convert a position in the buffer in row/column coordinates to an
  # absolute character offset, inclusive of line ending characters.
  #
  # The position is clipped prior to translating.
  #
  # position - A {Point}.
  #
  # Returns a {Number}.
  characterIndexForPosition: (position) ->
    {row, column} = @clipPosition(Point.fromObject(position))

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  # Public: Convert an absolute character offset, inclusive of newlines, to a
  # position in the buffer in row/column coordinates.
  #
  # The offset is clipped prior to translating.
  #
  # offset - A {Number}.
  #
  # Returns a {Point}.
  positionForCharacterIndex: (offset) ->
    offset = Math.max(0, offset)
    offset = Math.min(@getMaxCharacterIndex(), offset)

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getEndPosition()
    else
      new Point(rows, offset - characters)

  # Public: Get the length of the buffer in characters.
  #
  # Returns a {Number}.
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

  # Public: Reload the buffer's contents from disk.
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

  # Get the basename of the associated file.
  #
  # The basename is the name portion of the file's path, without the containing
  # directories.
  #
  # Returns a {String}.
  getBaseName: ->
    @file?.getBaseName()

  # Pubilc: Get the path of the associated file.
  #
  # Returns a {String}.
  getPath: ->
    @file?.getPath()

  # Public: Get the path of the associated file.
  #
  # Returns a {String}.
  getUri: ->
    @getPath()

  # Public: Set the path for the buffer's associated file.
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

  # Deprecated: Use {::getEndPosition} instead
  getEofPosition: -> @getEndPosition()

  # Public: Save the buffer.
  save: ->
    @saveAs(@getPath()) if @isModified()

  # Public: Save the buffer at a specific path.
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

  # Public: Determine if the in-memory contents of the buffer conflict with the
  # on-disk contents of its associated file.
  #
  # Returns a {Boolean}.
  isInConflict: -> @conflict

  destroyMarker: (id) ->
    @getMarker(id)?.destroy()

  # Identifies if a character sequence is within a certain range.
  #
  # regex - The {RegExp} to match.
  # startIndex - A {Number} representing the starting character offset.
  # endIndex - A {Number} representing the ending character offset.
  #
  # Returns an {Array} of matches for the given regex.
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

  # Public: Scan regular expression matches in the entire buffer, calling the
  # given iterator function on each match.
  #
  # If you're programmatically modifying the results, you may want to try
  # {::backwardsScan} to avoid tripping over your own changes.
  #
  # regex - A {RegExp} to search for.
  # iterator -
  #   A {Function} that's called on each match with an {Object} containing the.
  #   following keys:
  #   :match - The current regular expression match.
  #   :matchText - A {String} with the text of the match.
  #   :range - The {Range} of the match.
  #   :stop - Call this {Function} to terminate the scan.
  #   :replace - Call this {Function} with a {String} to replace the match.
  scan: (regex, iterator) ->
    @scanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Scan regular expression matches in the entire buffer in reverse
  # order, calling the given iterator function on each match.
  #
  # regex - A {RegExp} to search for.
  # iterator -
  #   A {Function} that's called on each match with an {Object} containing the.
  #   following keys:
  #   :match - The current regular expression match.
  #   :matchText - A {String} with the text of the match.
  #   :range - The {Range} of the match.
  #   :stop - Call this {Function} to terminate the scan.
  #   :replace - Call this {Function} with a {String} to replace the match.
  backwardsScan: (regex, iterator) ->
    @backwardsScanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Replace all regular expression matches in the entire buffer.
  #
  # regex - A {RegExp} representing the matches to be replaced.
  # replacementText - A {String} representing the text to replace each match.
  #
  # Returns a {Number} representing the number of replacements made.
  replace: (regex, replacementText) ->
    doSave = !@isModified()
    replacements = 0

    @transact =>
      @scan regex, ({matchText, replace}) ->
        replace(matchText.replace(regex, replacementText))
        replacements++

    @save() if doSave

    replacements

  # Public: Scan regular expression matches in a given range , calling the given
  # iterator function on each match.
  #
  # regex - A {RegExp} to search for.
  # range - A {Range} in which to search.
  # iterator -
  #   A {Function} that's called on each match with an {Object} containing the.
  #   following keys:
  #   :match - The current regular expression match.
  #   :matchText - A {String} with the text of the match.
  #   :range - The {Range} of the match.
  #   :stop - Call this {Function} to terminate the scan.
  #   :replace - Call this {Function} with a {String} to replace the match.
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

  # Public: Scan regular expression matches in a given range in reverse order,
  # calling the given iterator function on each match.
  #
  # regex - A {RegExp} to search for.
  # range - A {Range} in which to search.
  # iterator -
  #   A {Function} that's called on each match with an {Object} containing the.
  #   following keys:
  #   :match - The current regular expression match.
  #   :matchText - A {String} with the text of the match.
  #   :range - The {Range} of the match.
  #   :stop - Call this {Function} to terminate the scan.
  #   :replace - Call this {Function} with a {String} to replace the match.
  backwardsScanInRange: (regex, range, iterator) ->
    @scanInRange regex, range, iterator, true

  # Public: Determine if the given row contains only whitespace.
  #
  # row - A {Number} representing a 0-indexed row.
  #
  # Returns a {Boolean}.
  isRowBlank: (row) ->
    not /\S/.test @lineForRow(row)

  # Public: Given a row, find the first preceding row that's not blank.
  #
  # startRow - A {Number} identifying the row to start checking at.
  #
  # Returns a {Number} or `null` if there's no preceding non-blank row.
  previousNonBlankRow: (startRow) ->
    return null if startRow == 0

    startRow = Math.min(startRow, @getLastRow())
    for row in [(startRow - 1)..0]
      return row unless @isRowBlank(row)
    null

  # Public: Given a row, find the next row that's not blank.
  #
  # startRow - A {Number} identifying the row to start checking at.
  #
  # Returns a {Number} or `null` if there's no next non-blank row.
  nextNonBlankRow: (startRow) ->
    lastRow = @getLastRow()
    if startRow < lastRow
      for row in [(startRow + 1)..lastRow]
        return row unless @isRowBlank(row)
    null

  # Public: Determine if the buffer uses soft tabs.
  #
  # Returns `true` if the first line with leading whitespace starts with a
  # space character. Returns `false` if it starts with a hard tab (`\t`).
  #
  # Returns a {Boolean},
  usesSoftTabs: ->
    for row in [0..@getLastRow()]
      if match = @lineForRow(row).match(/^\s/)
        return match[0][0] != '\t'
    undefined

  # Deprecated: Call {::setTextInRange} instead.
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

  @delegatesMethods 'undo', 'redo', 'transact', 'beginTransaction', 'commitTransaction',
    'abortTransaction', 'isTransacting', 'clearUndoStack', toProperty: 'history'

  # Public: Undo the last operation. If a transaction is in progress, aborts it.
  undo: -> @history.undo()

  # Public: Redo the last operation
  redo: -> @history.redo()

  # Public: Batch multiple operations as a single undo/redo step.
  #
  # Any group of operations that are logically grouped from the perspective of
  # undoing and redoing should be performed in a transaction. If you want to
  # abort the transaction, call {::abortTransaction} to terminate the function's
  # execution and revert any changes performed up to the abortion.
  #
  # fn - A {Function} to call inside the transaction.
  transact: (fn) -> @history.transact(fn)

  # Public: Start an open-ended transaction.
  #
  # Call {::commitTransaction} or {::abortTransaction} to terminate the
  # transaction. If you nest calls to transactions, only the outermost
  # transaction is considered. You must match every begin with a matching
  # commit, but a single call to abort will cancel all nested transactions.
  beginTransaction: -> @history.beginTransaction()

  # Public: Commit an open-ended transaction started with {::beginTransaction}
  # and push it to the undo stack.
  #
  # If transactions are nested, only the outermost commit takes effect.
  commitTransaction: -> @history.commitTransaction()

  # Public: Abort an open transaction, undoing any operations performed so far
  # within the transaction.
  abortTransaction: -> @history.abortTransaction()

  # Public: Clear the undo stack.
  clearUndoStack: -> @history.clearUndoStack()

  # Public: Create a marker with the given range. This marker will maintain
  # its logical location as the buffer is changed, so if you mark a particular
  # word, the marker will remain over that word even if the word's location in
  # the buffer changes.
  #
  # * range: A {Range} or range-compatible {Array}
  # * properties:
  #     A hash of key-value pairs to associate with the marker. There are also
  #     reserved property names that have marker-specific meaning:
  #       :reversed -
  #         Creates the marker in a reversed orientation. Defaults to false.
  #       :persistent -
  #         Whether to include this marker when serializing the buffer. Defaults
  #         to true.
  #       :invalidate -
  #         Determines the rules by which changes to the buffer *invalidate* the
  #         marker. Defaults to 'overlap', but can be any of the following:
  #         * 'never':
  #             The marker is never marked as invalid. This is a good choice for
  #             markers representing selections in an editor.
  #         * 'surround':
  #             The marker is invalidated by changes that completely surround it.
  #         * 'overlap':
  #             The marker is invalidated by changes that surround the start or
  #             end of the marker. This is the default.
  #         * 'inside':
  #             The marker is invalidated by a change that touches the marked
  #             region in any way. This is the most fragile strategy.
  #
  # Returns a {Marker}.
  markRange: (range, properties) -> @markers.markRange(range, properties)

  # Public: Create a marker at the given position with no tail.
  #
  # :position - {Point} or point-compatible {Array}
  # :properties - This is the same as the `properties` parameter in {::markRange}
  #
  # Returns a {Marker}.
  markPosition: (position, properties) -> @markers.markPosition(position, properties)

  # Public: Get an existing marker by its id.
  #
  # Returns a {Marker}.
  getMarker: (id) -> @markers.getMarker(id)

  # Public: Get all existing markers on the buffer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: -> @markers.getMarkers()

  # Public: Find markers conforming to the given parameters.
  #
  # :params -
  #   A hash of key-value pairs constraining the set of returned markers. You
  #   can query against custom marker properties by listing the desired
  #   key-value pairs here. In addition, the following keys are reserved and
  #   have special semantics:
  #   * 'startPosition': Only include markers that start at the given {Point}.
  #   * 'endPosition': Only include markers that end at the given {Point}.
  #   * 'containsPoint': Only include markers that contain the given {Point}, inclusive.
  #   * 'containsRange': Only include markers that contain the given {Range}, inclusive.
  #   * 'startRow': Only include markers that start at the given row {Number}.
  #   * 'endRow': Only include markers that end at the given row {Number}.
  #   * 'intersectsRow': Only include markers that intersect the given row {Number}.
  #
  # Finds markers that conform to all of the given parameters. Markers are
  # sorted based on their position in the buffer. If two markers start at the
  # same position, the larger marker comes first.
  #
  # Returns an {Array} of {Marker}s.
  findMarkers: (params) -> @markers.findMarkers(params)

  # Public: Get the number of markers in the buffer.
  #
  # Returns a {Number}.
  getMarkerCount: -> @markers.getMarkerCount()
