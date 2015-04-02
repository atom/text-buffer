Delegator = require 'delegato'
Grim = require 'grim'
Serializable = require 'serializable'
{Emitter, CompositeDisposable} = require 'event-kit'
{File} = require 'pathwatcher'
SpanSkipList = require 'span-skip-list'
diff = require 'atom-diff'
Q = require 'q'
Point = require './point'
Range = require './range'
History = require './history'
MarkerManager = require './marker-manager'
BufferPatch = require './buffer-patch'
{spliceArray, newlineRegex} = require './helpers'

# Extended: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
module.exports =
class TextBuffer
  @Point: Point
  @Range: Range
  @newlineRegex: newlineRegex

  Delegator.includeInto(this)
  Serializable.includeInto(this)

  cachedText: null
  encoding: null
  stoppedChangingDelay: 300
  stoppedChangingTimeout: null
  cachedDiskContents: null
  conflict: false
  file: null
  refcount: 0
  fileSubscriptions: null

  @delegatesMethods 'undo', 'redo', 'transact', 'beginTransaction', 'commitTransaction',
    'abortTransaction', 'isTransacting', 'clearUndoStack', toProperty: 'history'

  ###
  Section: Construction
  ###

  # Public: Create a new buffer with the given params.
  #
  # * `params` {Object} or {String} of text
  #   * `load` A {Boolean}, `true` to asynchronously load the buffer from disk
  #     after initialization.
  #   * `text` The initial {String} text of the buffer.
  constructor: (params) ->
    text = params if typeof params is 'string'

    @emitter = new Emitter
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', normalizeLineEndings: false)
    @history = params?.history ? new History(this)
    @markers = params?.markers ? new MarkerManager(this)
    @setEncoding(params?.encoding)

    @loaded = false
    @digestWhenLastPersisted = params?.digestWhenLastPersisted ? false
    @modifiedWhenLastPersisted = params?.modifiedWhenLastPersisted ? false
    @useSerializedText = @modifiedWhenLastPersisted isnt false

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
    encoding: @getEncoding()
    filePath: @getPath()
    modifiedWhenLastPersisted: @isModified()
    digestWhenLastPersisted: @file?.getDigestSync()

  ###
  Section: Event Subscription
  ###

  # Public: Invoke the given callback synchronously _before_ the content of the
  # buffer changes.
  #
  # Because observers are invoked synchronously, it's important not to perform
  # any expensive operations via this method.
  #
  # * `callback` {Function} to be called when the buffer changes.
  #   * `event` {Object} with the following keys:
  #     * `oldRange` {Range} of the old text.
  #     * `newRange` {Range} of the new text.
  #     * `oldText` {String} containing the text that was replaced.
  #     * `newText` {String} containing the text that was inserted.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillChange: (callback) ->
    @emitter.on 'will-change', callback

  # Public: Invoke the given callback synchronously when the content of the
  # buffer changes.
  #
  # Because observers are invoked synchronously, it's important not to perform
  # any expensive operations via this method. Consider {::onDidStopChanging} to
  # delay expensive operations until after changes stop occurring.
  #
  # * `callback` {Function} to be called when the buffer changes.
  #   * `event` {Object} with the following keys:
  #     * `oldRange` {Range} of the old text.
  #     * `newRange` {Range} of the new text.
  #     * `oldText` {String} containing the text that was replaced.
  #     * `newText` {String} containing the text that was inserted.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  preemptDidChange: (callback) ->
    @emitter.preempt 'did-change', callback

  # Public: Invoke the given callback asynchronously following one or more
  # changes after {::getStoppedChangingDelay} milliseconds elapse without an
  # additional change.
  #
  # This method can be used to perform potentially expensive operations that
  # don't need to be performed synchronously. If you need to run your callback
  # synchronously, use {::onDidChange} instead.
  #
  # * `callback` {Function} to be called when the buffer stops changing.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidStopChanging: (callback) ->
    @emitter.on 'did-stop-changing', callback

  # Public: Invoke the given callback when the in-memory contents of the
  # buffer become in conflict with the contents of the file on disk.
  #
  # * `callback` {Function} to be called when the buffer enters conflict.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidConflict: (callback) ->
    @emitter.on 'did-conflict', callback

  # Public: Invoke the given callback the value of {::isModified} changes.
  #
  # * `callback` {Function} to be called when {::isModified} changes.
  #   * `modified` {Boolean} indicating whether the buffer is modified.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeModified: (callback) ->
    @emitter.on 'did-change-modified', callback

  # Public: Invoke the given callback when all marker `::onDidChange`
  # observers have been notified following a change to the buffer.
  #
  # The order of events following a buffer change is as follows:
  #
  # * The text of the buffer is changed
  # * All markers are updated accordingly, but their `::onDidChange` observers
  #   are not notified.
  # * `TextBuffer::onDidChange` observers are notified.
  # * `Marker::onDidChange` observers are notified.
  # * `TextBuffer::onDidUpdateMarkers` observers are notified.
  #
  # Basically, this method gives you a way to take action after both a buffer
  # change and all associated marker changes.
  #
  # * `callback` {Function} to be called after markers are updated.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidUpdateMarkers: (callback) ->
    @emitter.on 'did-update-markers', callback

  # Public: Invoke the given callback when a marker is created.
  #
  # * `callback` {Function} to be called when a marker is created.
  #   * `marker` {Marker} that was created.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidCreateMarker: (callback) ->
    @emitter.on 'did-create-marker', callback

  # Public: Invoke the given callback when the value of {::getPath} changes.
  #
  # * `callback` {Function} to be called when the path changes.
  #   * `path` {String} representing the buffer's current path on disk.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangePath: (callback) ->
    @emitter.on 'did-change-path', callback

  # Public: Invoke the given callback when the value of {::getEncoding} changes.
  #
  # * `callback` {Function} to be called when the encoding changes.
  #   * `encoding` {String} character set encoding of the buffer.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeEncoding: (callback) ->
    @emitter.on 'did-change-encoding', callback

  # Public: Invoke the given callback before the buffer is saved to disk.
  #
  # * `callback` {Function} to be called before the buffer is saved.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillSave: (callback) ->
    @emitter.on 'will-save', callback

  # Public: Invoke the given callback after the buffer is saved to disk.
  #
  # * `callback` {Function} to be called after the buffer is saved.
  #   * `event` {Object} with the following keys:
  #     * `path` The path to which the buffer was saved.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidSave: (callback) ->
    @emitter.on 'did-save', callback


  # Public: Invoke the given callback after the file backing the buffer is
  # deleted.
  #
  # * `callback` {Function} to be called after the buffer is deleted.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDelete: (callback) ->
    @emitter.on 'did-delete', callback

  # Public: Invoke the given callback before the buffer is reloaded from the
  # contents of its file on disk.
  #
  # * `callback` {Function} to be called before the buffer is reloaded.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillReload: (callback) ->
    @emitter.on 'will-reload', callback

  # Public: Invoke the given callback after the buffer is reloaded from the
  # contents of its file on disk.
  #
  # * `callback` {Function} to be called after the buffer is reloaded.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidReload: (callback) ->
    @emitter.on 'did-reload', callback

  # Public: Invoke the given callback when the buffer is destroyed.
  #
  # * `callback` {Function} to be called when the buffer is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  # Public: Invoke the given callback when there is an error in watching the
  # file.
  #
  # * `callback` {Function} callback
  #   * `errorObject` {Object}
  #     * `error` {Object} the error object
  #     * `handle` {Function} call this to indicate you have handled the error.
  #       The error will not be thrown if this function is called.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillThrowWatchError: (callback) ->
    @emitter.on 'will-throw-watch-error', callback

  # Public: Get the number of milliseconds that will elapse without a change
  # before {::onDidStopChanging} observers are invoked following a change.
  #
  # Returns a {Number}.
  getStoppedChangingDelay: -> @stoppedChangingDelay

  ###
  Section: File Details
  ###

  # Public: Determine if the in-memory contents of the buffer differ from its
  # contents on disk.
  #
  # If the buffer is unsaved, always returns `true` unless the buffer is empty.
  #
  # Returns a {Boolean}.
  isModified: ->
    return false unless @loaded
    if @file
      if @file.existsSync()
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

  # Public: Get the path of the associated file.
  #
  # Returns a {String}.
  getPath: ->
    @file?.getPath()

  # Public: Set the path for the buffer's associated file.
  #
  # * `filePath` A {String} representing the new file path
  setPath: (filePath) ->
    return if filePath == @getPath()

    if filePath
      @file = new File(filePath)
      @file.setEncoding(@getEncoding())
      @subscribeToFile()
    else
      @file = null

    @emitter.emit 'did-change-path', @getPath()
    @emit "path-changed", this if Grim.includeDeprecatedAPIs

  # Public: Sets the character set encoding for this buffer.
  #
  # * `encoding` The {String} encoding to use (default: 'utf8').
  setEncoding: (encoding='utf8') ->
    return if encoding is @getEncoding()

    @encoding = encoding
    if @file?
      @file.setEncoding(encoding)
      @emitter.emit 'did-change-encoding', encoding

      unless @isModified()
        @updateCachedDiskContents true, =>
          @reload()
          @clearUndoStack()
    else
      @emitter.emit 'did-change-encoding', encoding

    return

  # Public: Returns the {String} encoding of this buffer.
  getEncoding: -> @encoding ? @file?.getEncoding()

  # Public: Get the path of the associated file.
  #
  # Returns a {String}.
  getUri: ->
    @getPath()

  # Get the basename of the associated file.
  #
  # The basename is the name portion of the file's path, without the containing
  # directories.
  #
  # Returns a {String}.
  getBaseName: ->
    @file?.getBaseName()

  ###
  Section: Reading Text
  ###

  # Public: Determine whether the buffer is empty.
  #
  # Returns a {Boolean}.
  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

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

  # Public: Get the text in a range.
  #
  # * `range` A {Range}
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

  # Public: Get the text of all lines in the buffer, without their line endings.
  #
  # Returns an {Array} of {String}s.
  getLines: ->
    @lines.slice()

  # Public: Get the text of the last line of the buffer, without its line
  # ending.
  #
  # Returns a {String}.
  getLastLine: ->
    @lineForRow(@getLastRow())

  # Public: Get the text of the line at the given row, without its line ending.
  #
  # * `row` A {Number} representing a 0-indexed row.
  #
  # Returns a {String}.
  lineForRow: (row) ->
    @lines[row]

  # Public: Get the line ending for the given 0-indexed row.
  #
  # * `row` A {Number} indicating the row.
  #
  # Returns a {String}. The returned newline is represented as a literal string:
  # `'\n'`, `'\r'`, `'\r\n'`, or `''` for the last line of the buffer, which
  # doesn't end in a newline.
  lineEndingForRow: (row) ->
    @lineEndings[row]

  # Public: Get the length of the line for the given 0-indexed row, without its
  # line ending.
  #
  # * `row` A {Number} indicating the row.
  #
  # Returns a {Number}.
  lineLengthForRow: (row) ->
    @lines[row].length

  # Public: Determine if the given row contains only whitespace.
  #
  # * `row` A {Number} representing a 0-indexed row.
  #
  # Returns a {Boolean}.
  isRowBlank: (row) ->
    not /\S/.test @lineForRow(row)

  # Public: Given a row, find the first preceding row that's not blank.
  #
  # * `startRow` A {Number} identifying the row to start checking at.
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
  # * `startRow` A {Number} identifying the row to start checking at.
  #
  # Returns a {Number} or `null` if there's no next non-blank row.
  nextNonBlankRow: (startRow) ->
    lastRow = @getLastRow()
    if startRow < lastRow
      for row in [(startRow + 1)..lastRow]
        return row unless @isRowBlank(row)
    null

  ###
  Section: Mutating Text
  ###

  # Public: Replace the entire contents of the buffer with the given text.
  #
  # * `text` A {String}
  #
  # Returns a {Range} spanning the new buffer contents.
  setText: (text) ->
    @setTextInRange(@getRange(), text, normalizeLineEndings: false)

  # Public: Replace the current buffer contents by applying a diff based on the
  # given text.
  #
  # * `text` A {String} containing the new buffer contents.
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
        lineCount = change.value.match(newlineRegex)?.length ? 0
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
      return

  # Public: Set the text in the given range.
  #
  # * `range` A {Range}
  # * `text` A {String}
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text.
  setTextInRange: (range, text, options) ->
    if Grim.includeDeprecatedAPIs and typeof options is 'boolean'
      normalizeLineEndings = options
      Grim.deprecate("The normalizeLineEndings argument is now an options hash. Use {normalizeLineEndings: #{options}} instead")
    else if options?
      {normalizeLineEndings, undo} = options
    normalizeLineEndings ?= true

    patch = @buildPatch(range, text, normalizeLineEndings)
    @history?.recordNewPatch(patch) unless undo is 'skip'
    @applyPatch(patch)
    patch.newRange

  # Public: Insert text at the given position.
  #
  # * `position` A {Point} representing the insertion location. The position is
  #   clipped before insertion.
  # * `text` A {String} representing the text to insert.
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text.
  insert: (position, text, options) ->
    @setTextInRange(new Range(position, position), text, options)

  # Public: Append text to the end of the buffer.
  #
  # * `text` A {String} representing the text text to append.
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text
  append: (text, options) ->
    @insert(@getEndPosition(), text, options)

  # Builds a {BufferPatch}, which is used to modify the buffer and is also
  # pushed into the undo history so it can be undone.
  buildPatch: (oldRange, newText, normalizeLineEndings) ->
    oldRange = @clipRange(oldRange)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    new BufferPatch(oldRange, newRange, oldText, newText, normalizeLineEndings)

  # Applies a {BufferPatch} to the buffer based on its old range and new text.
  # Also applies any {MarkerPatch}es associated with the {BufferPatch}.
  applyPatch: (patch) ->
    {oldRange, newRange, oldText, newText, normalizeLineEndings} = patch
    @cachedText = null

    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    @emitter.emit 'will-change', {oldRange, newRange, oldText, newText}

    # Determine how to normalize the line endings of inserted text if enabled
    if normalizeLineEndings
      normalizedEnding = @lineEndingForRow(startRow)
      if normalizedEnding is ''
        if startRow > 0
          normalizedEnding = @lineEndingForRow(startRow - 1)
        else
          normalizedEnding = null

    # Split inserted text into lines and line endings
    lines = []
    lineEndings = []
    lineStartIndex = 0
    while result = newlineRegex.exec(newText)
      lines.push(newText[lineStartIndex...result.index])
      lineEndings.push(normalizedEnding ? result[0])
      lineStartIndex = newlineRegex.lastIndex

    lastLine = newText[lineStartIndex..]
    lines.push(lastLine)
    lineEndings.push('')

    # Update first and last line so replacement preserves existing prefix and suffix of oldRange
    prefix = @lineForRow(startRow)[0...oldRange.start.column]
    lines[0] = prefix + lines[0]
    suffix = @lineForRow(endRow)[oldRange.end.column...]
    lastIndex = lines.length - 1
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
    @markers?.handleBufferChange(patch)

    changeEvent = {oldRange, newRange, oldText, newText}

    @conflict = false if @conflict and !@isModified()
    @scheduleModifiedEvents()
    @emitter.emit 'did-change', changeEvent
    @emit 'changed', changeEvent if Grim.includeDeprecatedAPIs
    @markers?.resumeChangeEvents()
    @emitter.emit 'did-update-markers'
    @emit 'markers-updated' if Grim.includeDeprecatedAPIs

  # Public: Delete the text in the given range.
  #
  # * `range` A {Range} in which to delete. The range is clipped before deleting.
  #
  # Returns an empty {Range} starting at the start of deleted range.
  delete: (range) ->
    @setTextInRange(range, '')

  # Public: Delete the line associated with a specified row.
  #
  # * `row` A {Number} representing the 0-indexed row to delete.
  #
  # Returns the {Range} of the deleted text.
  deleteRow: (row) ->
    @deleteRows(row, row)

  # Public: Delete the lines associated with the specified row range.
  #
  # If the row range is out of bounds, it will be clipped. If the startRow is
  # greater than the end row, they will be reordered.
  #
  # * `startRow` A {Number} representing the first row to delete.
  # * `endRow` A {Number} representing the last row to delete, inclusive.
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

  ###
  Section: Markers
  ###

  # Public: Create a marker with the given range. This marker will maintain
  # its logical location as the buffer is changed, so if you mark a particular
  # word, the marker will remain over that word even if the word's location in
  # the buffer changes.
  #
  # * `range` A {Range} or range-compatible {Array}
  # * `properties` A hash of key-value pairs to associate with the marker. There
  #   are also reserved property names that have marker-specific meaning.
  #   * `reversed` (optional) Creates the marker in a reversed orientation. (default: false)
  #   * `persistent` (optional) Whether to include this marker when serializing the buffer. (default: true)
  #   * `invalidate` (optional) Determines the rules by which changes to the
  #     buffer *invalidate* the marker. (default: 'overlap') It can be any of
  #     the following strategies, in order of fragility
  #     * __never__: The marker is never marked as invalid. This is a good choice for
  #       markers representing selections in an editor.
  #     * __surround__: The marker is invalidated by changes that completely surround it.
  #     * __overlap__: The marker is invalidated by changes that surround the
  #       start or end of the marker. This is the default.
  #     * __inside__: The marker is invalidated by changes that extend into the
  #       inside of the marker. Changes that end at the marker's start or
  #       start at the marker's end do not invalidate the marker.
  #     * __touch__: The marker is invalidated by a change that touches the marked
  #       region in any way, including changes that end at the marker's
  #       start or start at the marker's end. This is the most fragile strategy.
  #
  # Returns a {Marker}.
  markRange: (range, properties) -> @markers.markRange(range, properties)

  # Public: Create a marker at the given position with no tail.
  #
  # * `position` {Point} or point-compatible {Array}
  # * `properties` This is the same as the `properties` parameter in {::markRange}
  #
  # Returns a {Marker}.
  markPosition: (position, properties) -> @markers.markPosition(position, properties)

  # Public: Get all existing markers on the buffer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: -> @markers.getMarkers()

  # Public: Get an existing marker by its id.
  #
  # * `id` {Number} id of the marker to retrieve
  #
  # Returns a {Marker}.
  getMarker: (id) -> @markers.getMarker(id)

  # Public: Find markers conforming to the given parameters.
  #
  # Markers are sorted based on their position in the buffer. If two markers
  # start at the same position, the larger marker comes first.
  #
  # * `params` A hash of key-value pairs constraining the set of returned markers. You
  #   can query against custom marker properties by listing the desired
  #   key-value pairs here. In addition, the following keys are reserved and
  #   have special semantics:
  #   * `startPosition` Only include markers that start at the given {Point}.
  #   * `endPosition` Only include markers that end at the given {Point}.
  #   * `containsPoint` Only include markers that contain the given {Point}, inclusive.
  #   * `containsRange` Only include markers that contain the given {Range}, inclusive.
  #   * `startRow` Only include markers that start at the given row {Number}.
  #   * `endRow` Only include markers that end at the given row {Number}.
  #   * `intersectsRow` Only include markers that intersect the given row {Number}.
  #
  # Returns an {Array} of {Marker}s.
  findMarkers: (params) -> @markers.findMarkers(params)

  # Public: Get the number of markers in the buffer.
  #
  # Returns a {Number}.
  getMarkerCount: -> @markers.getMarkerCount()

  destroyMarker: (id) ->
    @getMarker(id)?.destroy()

  ###
  Section: History
  ###

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
  # * `groupingInterval` (optional) The {Number} of milliseconds for which this
  #   transaction should be considered 'open for grouping' after it begins. If a
  #   transaction with a positive `groupingInterval` is committed while the previous
  #   transaction is still open for grouping, the two transactions are merged with
  #   respect to undo and redo.
  # * `fn` A {Function} to call inside the transaction.
  transact: (groupingInterval, fn) -> @history.transact(groupingInterval, fn)

  # Public: Clear the undo stack.
  clearUndoStack: -> @history.clearUndoStack()

  # Public: Create a pointer to the current state of the buffer for use
  # with {::revertToCheckpoint} and {::groupChangesSinceCheckpoint}.
  #
  # Returns a checkpoint value.
  createCheckpoint: -> @history.createCheckpoint()

  # Public: Revert the buffer to the state it was in when the given
  # checkpoint was created.
  #
  # The redo stack will be empty following this operation, so changes since the
  # checkpoint will be lost. If the given checkpoint is no longer present in the
  # undo history, no changes will be made to the buffer and this method will
  # return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  revertToCheckpoint: (checkpoint) -> @history.revertToCheckpoint(checkpoint)

  # Public: Group all changes since the given checkpoint into a single
  # transaction for purposes of undo/redo.
  #
  # If the given checkpoint is no longer present in the undo history, no
  # grouping will be performed and this method will return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  groupChangesSinceCheckpoint: (checkpoint) -> @history.groupChangesSinceCheckpoint(checkpoint)

  ###
  Section: Search And Replace
  ###

  # Public: Scan regular expression matches in the entire buffer, calling the
  # given iterator function on each match.
  #
  # If you're programmatically modifying the results, you may want to try
  # {::backwardsScan} to avoid tripping over your own changes.
  #
  # * `regex` A {RegExp} to search for.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  scan: (regex, iterator) ->
    @scanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Scan regular expression matches in the entire buffer in reverse
  # order, calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  backwardsScan: (regex, iterator) ->
    @backwardsScanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Scan regular expression matches in a given range , calling the given
  # iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
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
        @setTextInRange(range, replacementText)
        lengthDelta += replacementText.length - matchLength unless reverse

      break unless global and keepLooping
    return

  # Public: Scan regular expression matches in a given range in reverse order,
  # calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  backwardsScanInRange: (regex, range, iterator) ->
    @scanInRange regex, range, iterator, true

  # Public: Replace all regular expression matches in the entire buffer.
  #
  # * `regex` A {RegExp} representing the matches to be replaced.
  # * `replacementText` A {String} representing the text to replace each match.
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

  # Identifies if a character sequence is within a certain range.
  #
  # * `regex` The {RegExp} to match.
  # * `startIndex` A {Number} representing the starting character offset.
  # * `endIndex` A {Number} representing the ending character offset.
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

  ###
  Section: Buffer Range Details
  ###

  # Public: Get the range spanning from `[0, 0]` to {::getEndPosition}.
  #
  # Returns a {Range}.
  getRange: ->
    new Range(@getFirstPosition(), @getEndPosition())

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

  # Public: Get the length of the buffer in characters.
  #
  # Returns a {Number}.
  getMaxCharacterIndex: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters

  # Public: Get the range for the given row
  #
  # * `row` A {Number} representing a 0-indexed row.
  # * `includeNewline` A {Boolean} indicating whether or not to include the
  #   newline, which results in a range that extends to the start
  #   of the next line.
  #
  # Returns a {Range}.
  rangeForRow: (row, includeNewline) ->
    # Handle deprecated options hash
    if Grim.includeDeprecatedAPIs and typeof includeNewline is 'object'
      Grim.deprecate("The second param is no longer an object, it's a boolean argument named `includeNewline`.")
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
  # * `position` A {Point}.
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
  # * `offset` A {Number}.
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

  # Public: Clip the given range so it starts and ends at valid positions.
  #
  # For example, the position `[1, 100]` is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to `(1, 10)`.
  #
  # * `range` A {Range} or range-compatible {Array} to clip.
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
  # * `position` A {Point} or point-compatible {Array}.
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


  ###
  Section: Buffer Operations
  ###

  # Public: Save the buffer.
  save: ->
    @saveAs(@getPath())

  # Public: Save the buffer at a specific path.
  #
  # * `filePath` The path to save at.
  saveAs: (filePath) ->
    unless filePath then throw new Error("Can't save buffer with no file path")

    @emitter.emit 'will-save', {path: filePath}
    @emit 'will-be-saved', this if Grim.includeDeprecatedAPIs
    @setPath(filePath)
    @file.writeSync(@getText())
    @cachedDiskContents = @getText()
    @conflict = false
    @emitModifiedStatusChanged(false)
    @emitter.emit 'did-save', {path: filePath}
    @emit 'saved', this if Grim.includeDeprecatedAPIs

  # Public: Reload the buffer's contents from disk.
  #
  # Sets the buffer's content to the cached disk contents
  reload: ->
    @emitter.emit 'will-reload'
    @emit 'will-reload' if Grim.includeDeprecatedAPIs
    @setTextViaDiff(@cachedDiskContents)
    @emitModifiedStatusChanged(false)
    @emitter.emit 'did-reload'
    @emit 'reloaded' if Grim.includeDeprecatedAPIs

  # Rereads the contents of the file, and stores them in the cache.
  updateCachedDiskContentsSync: ->
    @cachedDiskContents = @file?.readSync() ? ""

  # Rereads the contents of the file, and stores them in the cache.
  #
  # * `flushCache` (optional) {Boolean} flush option to pass through to
  #                {File::read} (default: false).
  # * `callback`   (optional) {Function} to call after the cached contents have
  #                been updated.
  updateCachedDiskContents: (flushCache=false, callback) ->
    Q(@file?.read(flushCache) ? "").then (contents) =>
      @cachedDiskContents = contents
      callback?()

  ###
  Section: Private Utility Methods
  ###

  markerCreated: (marker) ->
    @emitter.emit 'did-create-marker', marker
    @emit 'marker-created', marker if Grim.includeDeprecatedAPIs

  loadSync: ->
    @updateCachedDiskContentsSync()
    @finishLoading()

  load: ->
    @updateCachedDiskContents().then => @finishLoading()

  finishLoading: ->
    if @isAlive()
      @loaded = true
      if @useSerializedText and @digestWhenLastPersisted is @file?.getDigestSync()
        @emitModifiedStatusChanged(true)
      else
        @reload()
      @clearUndoStack()
    this

  destroy: ->
    unless @destroyed
      @cancelStoppedChangingTimeout()
      @fileSubscriptions?.dispose()
      @unsubscribe() if Grim.includeDeprecatedAPIs
      @destroyed = true
      @emitter.emit 'did-destroy'
      @emit 'destroyed' if Grim.includeDeprecatedAPIs

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
    @fileSubscriptions?.dispose()
    @fileSubscriptions = new CompositeDisposable

    @fileSubscriptions.add @file.onDidChange =>
      @conflict = true if @isModified()
      previousContents = @cachedDiskContents

      # Synchrounously update the disk contents because the {File} has already cached them. If the
      # contents updated asynchrounously multiple `conlict` events could trigger for the same disk
      # contents.
      @updateCachedDiskContentsSync()
      return if previousContents == @cachedDiskContents

      if @conflict
        @emitter.emit 'did-conflict'
        @emit "contents-conflicted" if Grim.includeDeprecatedAPIs
      else
        @reload()

    @fileSubscriptions.add @file.onDidDelete =>
      modified = @getText() != @cachedDiskContents
      @wasModifiedBeforeRemove = modified
      @emitter.emit 'did-delete'
      if modified
        @updateCachedDiskContents()
      else
        @destroy()

    @fileSubscriptions.add @file.onDidRename =>
      @emitter.emit 'did-change-path', @getPath()
      @emit "path-changed", this if Grim.includeDeprecatedAPIs

    @fileSubscriptions.add @file.onWillThrowWatchError (errorObject) =>
      @emitter.emit 'will-throw-watch-error', errorObject

  # Identifies if the buffer belongs to multiple editors.
  #
  # For example, if the {EditorView} was split.
  #
  # Returns a {Boolean}.
  hasMultipleEditors: -> @refcount > 1

  cancelStoppedChangingTimeout: ->
    clearTimeout(@stoppedChangingTimeout) if @stoppedChangingTimeout

  scheduleModifiedEvents: ->
    @cancelStoppedChangingTimeout()
    stoppedChangingCallback = =>
      @stoppedChangingTimeout = null
      modifiedStatus = @isModified()
      @emitter.emit 'did-stop-changing'
      @emit 'contents-modified', modifiedStatus if Grim.includeDeprecatedAPIs
      @emitModifiedStatusChanged(modifiedStatus)
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  emitModifiedStatusChanged: (modifiedStatus) ->
    return if modifiedStatus is @previousModifiedStatus
    @previousModifiedStatus = modifiedStatus
    @emitter.emit 'did-change-modified', modifiedStatus
    @emit 'modified-status-changed', modifiedStatus if Grim.includeDeprecatedAPIs

  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row)
      console.log row, line, line.length
    return

if Grim.includeDeprecatedAPIs
  EmitterMixin = require('emissary').Emitter
  EmitterMixin.includeInto(TextBuffer)

  {Subscriber} = require 'emissary'
  Subscriber.includeInto(TextBuffer)

  TextBuffer::on = (eventName) ->
    switch eventName
      when 'changed'
        Grim.deprecate("Use TextBuffer::onDidChange instead")
      when 'contents-modified'
        Grim.deprecate("Use TextBuffer::onDidStopChanging instead. If you need the modified status, call TextBuffer::isModified yourself in your callback.")
      when 'contents-conflicted'
        Grim.deprecate("Use TextBuffer::onDidConflict instead")
      when 'modified-status-changed'
        Grim.deprecate("Use TextBuffer::onDidChangeModified instead")
      when 'markers-updated'
        Grim.deprecate("Use TextBuffer::onDidUpdateMarkers instead")
      when 'marker-created'
        Grim.deprecate("Use TextBuffer::onDidCreateMarker instead")
      when 'path-changed'
        Grim.deprecate("Use TextBuffer::onDidChangePath instead. The path is now provided as a callback argument rather than a TextBuffer instance.")
      when 'will-be-saved'
        Grim.deprecate("Use TextBuffer::onWillSave instead. A TextBuffer instance is no longer provided as a callback argument.")
      when 'saved'
        Grim.deprecate("Use TextBuffer::onDidSave instead. A TextBuffer instance is no longer provided as a callback argument.")
      when 'will-reload'
        Grim.deprecate("Use TextBuffer::onWillReload instead.")
      when 'reloaded'
        Grim.deprecate("Use TextBuffer::onDidReload instead.")
      when 'destroyed'
        Grim.deprecate("Use TextBuffer::onDidDestroy instead")
      else
        Grim.deprecate("TextBuffer::on is deprecated. Use event subscription methods instead.")

    EmitterMixin::on.apply(this, arguments)

  TextBuffer::change = (oldRange, newText, options={}) ->
    Grim.deprecate("Use TextBuffer::setTextInRange instead.")
    @setTextInRange(oldRange, newText, options.normalizeLineEndings)

  TextBuffer::usesSoftTabs = ->
    Grim.deprecate("Use TextEditor::usesSoftTabs instead. TextBuffer doesn't have enough context to determine this.")
    for row in [0..@getLastRow()]
      if match = @lineForRow(row).match(/^\s/)
        return match[0][0] != '\t'
    undefined

  TextBuffer::getEofPosition = ->
    Grim.deprecate("Use TextBuffer::getEndPosition instead.")
    @getEndPosition()

  TextBuffer::beginTransaction = (groupingInterval) ->
    Grim.deprecate("Open-ended transactions are deprecated. Use checkpoints instead.")
    @history.beginTransaction(groupingInterval)

  TextBuffer::commitTransaction = ->
    Grim.deprecate("Open-ended transactions are deprecated. Use checkpoints instead.")
    @history.commitTransaction()

  TextBuffer::abortTransaction = ->
    Grim.deprecate("Open-ended transactions are deprecated. Use checkpoints instead.")
    @history.abortTransaction()
