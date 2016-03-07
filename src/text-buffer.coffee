{Emitter, CompositeDisposable} = require 'event-kit'
{File} = require 'pathwatcher'
SpanSkipList = require 'span-skip-list'
diff = require 'atom-diff'
_ = require 'underscore-plus'
fs = require 'fs-plus'
path = require 'path'
crypto = require 'crypto'
Patch = require 'atom-patch'

Point = require './point'
Range = require './range'
History = require './history'
MarkerLayer = require './marker-layer'
MatchIterator = require './match-iterator'
{spliceArray, newlineRegex, normalizePatchChanges} = require './helpers'

class SearchCallbackArgument
  Object.defineProperty @::, "range",
    get: ->
      return @computedRange if @computedRange?

      matchStartIndex = @match.index
      matchEndIndex = matchStartIndex + @matchText.length

      startPosition = @buffer.positionForCharacterIndex(matchStartIndex + @lengthDelta)
      endPosition = @buffer.positionForCharacterIndex(matchEndIndex + @lengthDelta)

      @computedRange = new Range(startPosition, endPosition)

    set: (range) ->
      @computedRange = range

  constructor: (@buffer, @match, @lengthDelta) ->
    @stopped = false
    @replacementText = null
    @matchText = @match[0]

  getReplacementDelta: ->
    return 0 unless @replacementText?

    @replacementText.length - @matchText.length

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: =>
    @stopped = true

  keepLooping: ->
    @stopped is false

class TransactionAbortedError extends Error
  constructor: -> super

# Extended: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
module.exports =
class TextBuffer
  @version: 5
  @Point: Point
  @Range: Range
  @Patch: require('./patch')
  @newlineRegex: newlineRegex

  cachedText: null
  encoding: null
  stoppedChangingDelay: 300
  stoppedChangingTimeout: null
  cachedDiskContents: null
  conflict: false
  file: null
  refcount: 0
  fileSubscriptions: null
  backwardsScanChunkSize: 8000
  defaultMaxUndoEntries: 10000
  changeCount: 0
  nextMarkerLayerId: 0

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
    @patchesSinceLastStoppedChangingEvent = []
    @didChangeTextPatch = new Patch
    @id = params?.id ? crypto.randomBytes(16).toString('hex')
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', normalizeLineEndings: false)
    maxUndoEntries = params?.maxUndoEntries ? @defaultMaxUndoEntries
    @history = params?.history ? new History(maxUndoEntries)
    @nextMarkerLayerId = params?.nextMarkerLayerId ? 0
    @defaultMarkerLayer = params?.defaultMarkerLayer ? new MarkerLayer(this, String(@nextMarkerLayerId++))
    @markerLayers = params?.markerLayers ? {}
    @markerLayers[@defaultMarkerLayer.id] = @defaultMarkerLayer
    @nextMarkerId = params?.nextMarkerId ? 1

    @setEncoding(params?.encoding)
    @setPreferredLineEnding(params?.preferredLineEnding)

    @loaded = false
    @transactCallDepth = 0
    @digestWhenLastPersisted = params?.digestWhenLastPersisted ? false

    @setPath(params.filePath) if params?.filePath
    @load() if params?.load

  @deserialize: (params) ->
    buffer = Object.create(TextBuffer.prototype)
    markerLayers = {}
    for layerId, layerState of params.markerLayers
      markerLayers[layerId] = MarkerLayer.deserialize(buffer, layerState)
    params.markerLayers = markerLayers
    params.defaultMarkerLayer = params.markerLayers[params.defaultMarkerLayerId]
    params.history = History.deserialize(params.history)
    params.load = true if params.filePath
    TextBuffer.call(buffer, params)
    buffer

  # Returns a {String} representing a unique identifier for this {TextBuffer}.
  getId: ->
    @id

  serialize: (options) ->
    options ?= {}
    options.markerLayers ?= true

    markerLayers = {}
    if options.markerLayers
      for id, layer of @markerLayers
        markerLayers[id] = layer.serialize() if layer.maintainHistory

    id: @getId()
    text: @getText()
    defaultMarkerLayerId: @defaultMarkerLayer.id
    markerLayers: markerLayers
    nextMarkerLayerId: @nextMarkerLayerId
    history: @history.serialize(options)
    encoding: @getEncoding()
    filePath: @getPath()
    digestWhenLastPersisted: @file?.getDigestSync()
    preferredLineEnding: @preferredLineEnding
    nextMarkerId: @nextMarkerId

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

  onDidChangeText: (callback) ->
    @emitter.on 'did-change-text', callback

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

  # Public: Invoke the given callback if the value of {::isModified} changes.
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
    if @file
      return false unless @loaded

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
        @updateCachedDiskContents true, => @reload(true)
    else
      @emitter.emit 'did-change-encoding', encoding

    return

  # Public: Returns the {String} encoding of this buffer.
  getEncoding: -> @encoding ? @file?.getEncoding()

  setPreferredLineEnding: (preferredLineEnding=null) ->
    @preferredLineEnding = preferredLineEnding

  getPreferredLineEnding: ->
    @preferredLineEnding

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
  setTextInRange: (range, newText, options) ->
    if @transactCallDepth is 0
      return @transact => @setTextInRange(range, newText, options)

    if options?
      {normalizeLineEndings, undo} = options
    normalizeLineEndings ?= true

    oldRange = @clipRange(range)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    change = {newStart: oldRange.start, oldExtent: oldRange.getExtent(), newExtent: newRange.getExtent(), oldText, newText, normalizeLineEndings}
    @history?.pushChange(change) if undo isnt 'skip'
    @applyChange(change)
    newRange

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

  # Applies a change to the buffer based on its old range and new text.
  applyChange: (change) ->
    {newStart, oldExtent, newExtent, oldText, newText, normalizeLineEndings} = change
    start = Point.fromObject(newStart)
    oldRange = Range(start, start.traverse(oldExtent))
    newRange = Range(start, start.traverse(newExtent))
    oldRange.freeze()
    newRange.freeze()
    @cachedText = null

    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    # Determine how to normalize the line endings of inserted text if enabled
    if normalizeLineEndings
      normalizedEnding = @preferredLineEnding ? @lineEndingForRow(startRow)
      unless normalizedEnding
        if startRow > 0
          normalizedEnding = @lineEndingForRow(startRow - 1)
        else
          normalizedEnding = null

    # Split inserted text into lines and line endings
    lines = []
    lineEndings = []
    lineStartIndex = 0
    normalizedNewText = ""
    while result = newlineRegex.exec(newText)
      line = newText[lineStartIndex...result.index]
      ending = normalizedEnding ? result[0]
      lines.push(line)
      lineEndings.push(ending)
      normalizedNewText += line + ending
      lineStartIndex = newlineRegex.lastIndex

    lastLine = newText[lineStartIndex..]
    lines.push(lastLine)
    lineEndings.push('')
    normalizedNewText += lastLine

    newText = normalizedNewText
    changeEvent = Object.freeze({oldRange, newRange, oldText, newText})
    @emitter.emit 'will-change', changeEvent

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

    if @markerLayers?
      oldExtent = oldRange.getExtent()
      newExtent = newRange.getExtent()
      for id, markerLayer of @markerLayers
        markerLayer.splice(oldRange.start, oldExtent, newExtent)

    @conflict = false if @conflict and !@isModified()

    @changeCount++
    @emitter.emit 'did-change', changeEvent

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

  # Public: *Experimental:* Create a layer to contain a set of related markers.
  #
  # * `options` An object contaning the following keys:
  #   * `maintainHistory` A {Boolean} indicating whether or not the state of
  #     this layer should be restored on undo/redo operations. Defaults to
  #     `false`.
  #
  # This API is experimental and subject to change on any release.
  #
  # Returns a {MarkerLayer}.
  addMarkerLayer: (options) ->
    layer = new MarkerLayer(this, String(@nextMarkerLayerId++), options)
    @markerLayers[layer.id] = layer
    layer

  # Public: *Experimental:* Get a {MarkerLayer} by id.
  #
  # * `id` The id of the marker layer to retrieve.
  #
  # This API is experimental and subject to change on any release.
  #
  # Returns a {MarkerLayer} or `undefined` if no layer exists with the given
  # id.
  getMarkerLayer: (id) ->
    @markerLayers[id]

  # Public: *Experimental:* Get the default {MarkerLayer}.
  #
  # All marker APIs not tied to an explicit layer interact with this default
  # layer.
  #
  # This API is experimental and subject to change on any release.
  #
  # Returns a {MarkerLayer}.
  getDefaultMarkerLayer: ->
    @defaultMarkerLayer

  # Public: Create a marker with the given range in the default marker layer.
  # This marker will maintain its logical location as the buffer is changed, so
  # if you mark a particular word, the marker will remain over that word even if
  # the word's location in the buffer changes.
  #
  # * `range` A {Range} or range-compatible {Array}
  # * `properties` A hash of key-value pairs to associate with the marker. There
  #   are also reserved property names that have marker-specific meaning.
  #   * `reversed` (optional) {Boolean} Creates the marker in a reversed
  #     orientation. (default: false)
  #   * `persistent` (optional) {Boolean} Whether to include this marker when
  #     serializing the buffer. (default: true)
  #   * `invalidate` (optional) {String} Determines the rules by which changes
  #     to the buffer *invalidate* the marker. (default: 'overlap') It can be
  #     any of the following strategies, in order of fragility:
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
  markRange: (range, properties) -> @defaultMarkerLayer.markRange(range, properties)

  # Public: Create a marker at the given position with no tail in the default
  # marker layer.
  #
  # * `position` {Point} or point-compatible {Array}
  # * `properties` This is the same as the `properties` parameter in {::markRange}
  #
  # Returns a {Marker}.
  markPosition: (position, properties) -> @defaultMarkerLayer.markPosition(position, properties)

  # Public: Get all existing markers on the default marker layer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: -> @defaultMarkerLayer.getMarkers()

  # Public: Get an existing marker by its id from the default marker layer.
  #
  # * `id` {Number} id of the marker to retrieve
  #
  # Returns a {Marker}.
  getMarker: (id) -> @defaultMarkerLayer.getMarker(id)

  # Public: Find markers conforming to the given parameters in the default
  # marker layer.
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
  findMarkers: (params) -> @defaultMarkerLayer.findMarkers(params)

  # Public: Get the number of markers in the default marker layer.
  #
  # Returns a {Number}.
  getMarkerCount: -> @defaultMarkerLayer.getMarkerCount()

  destroyMarker: (id) ->
    @getMarker(id)?.destroy()

  ###
  Section: History
  ###

  # Public: Undo the last operation. If a transaction is in progress, aborts it.
  undo: ->
    if pop = @history.popUndoStack()
      @applyChange(change) for change in pop.patch.getChanges()
      @restoreFromMarkerSnapshot(pop.snapshot)
      @emitMarkerChangeEvents(pop.snapshot)
      @emitDidChangeTextEvent(pop.patch)
      true
    else
      false

  # Public: Redo the last operation
  redo: ->
    if pop = @history.popRedoStack()
      @applyChange(change) for change in pop.patch.getChanges()
      @restoreFromMarkerSnapshot(pop.snapshot)
      @emitMarkerChangeEvents(pop.snapshot)
      @emitDidChangeTextEvent(pop.patch)
      true
    else
      false

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
  transact: (groupingInterval, fn) ->
    if typeof groupingInterval is 'function'
      fn = groupingInterval
      groupingInterval = 0

    checkpointBefore = @history.createCheckpoint(@createMarkerSnapshot(), true)

    try
      @transactCallDepth++
      result = fn()
    catch exception
      @revertToCheckpoint(checkpointBefore, true)
      throw exception unless exception instanceof TransactionAbortedError
      return
    finally
      @transactCallDepth--

    endMarkerSnapshot = @createMarkerSnapshot()
    compactedChanges = @history.groupChangesSinceCheckpoint(checkpointBefore, endMarkerSnapshot, true)
    @history.applyGroupingInterval(groupingInterval)
    @emitMarkerChangeEvents(endMarkerSnapshot)
    @emitDidChangeTextEvent(compactedChanges)
    result

  abortTransaction: ->
    throw new TransactionAbortedError("Transaction aborted.")

  # Public: Clear the undo stack.
  clearUndoStack: -> @history.clearUndoStack()

  # Public: Create a pointer to the current state of the buffer for use
  # with {::revertToCheckpoint} and {::groupChangesSinceCheckpoint}.
  #
  # Returns a checkpoint value.
  createCheckpoint: ->
    @history.createCheckpoint(@createMarkerSnapshot(), false)

  # Public: Revert the buffer to the state it was in when the given
  # checkpoint was created.
  #
  # The redo stack will be empty following this operation, so changes since the
  # checkpoint will be lost. If the given checkpoint is no longer present in the
  # undo history, no changes will be made to the buffer and this method will
  # return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  revertToCheckpoint: (checkpoint) ->
    if truncated = @history.truncateUndoStack(checkpoint)
      @applyChange(change) for change in truncated.patch.getChanges()
      @restoreFromMarkerSnapshot(truncated.snapshot)
      @emitter.emit 'did-update-markers'
      @emitDidChangeTextEvent(truncated.patch)
      true
    else
      false

  # Public: Group all changes since the given checkpoint into a single
  # transaction for purposes of undo/redo.
  #
  # If the given checkpoint is no longer present in the undo history, no
  # grouping will be performed and this method will return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  groupChangesSinceCheckpoint: (checkpoint) ->
    @history.groupChangesSinceCheckpoint(checkpoint, @createMarkerSnapshot(), false)

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

    if reverse
      matches = new MatchIterator.Backwards(@getText(), regex, startIndex, endIndex, @backwardsScanChunkSize)
    else
      matches = new MatchIterator.Forwards(@getText(), regex, startIndex, endIndex)

    lengthDelta = 0
    until (next = matches.next()).done
      match = next.value
      callbackArgument = new SearchCallbackArgument(this, match, lengthDelta)
      iterator(callbackArgument)
      lengthDelta += callbackArgument.getReplacementDelta() unless reverse

      break unless global and callbackArgument.keepLooping()
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
    row = Math.max(row, 0)
    row = Math.min(row, @getLastRow())

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
    Point.assertValid(position)
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
  save: (options) ->
    @saveAs(@getPath(), options)

  # Public: Save the buffer at a specific path.
  #
  # * `filePath` The path to save at.
  saveAs: (filePath, options) ->
    unless filePath then throw new Error("Can't save buffer with no file path")

    @emitter.emit 'will-save', {path: filePath}
    @setPath(filePath)

    if options?.backup
      backupFilePath = @backUpFileContentsBeforeWriting()

    try
      @file.writeSync(@getText())
      if backupFilePath?
        @removeBackupFileAfterWriting(backupFilePath)
    catch error
      if backupFilePath?
        fs.writeFileSync(filePath, fs.readFileSync(backupFilePath))
      throw error

    @cachedDiskContents = @getText()
    @conflict = false
    @emitModifiedStatusChanged(false)
    @emitter.emit 'did-save', {path: filePath}

  # Public: Reload the buffer's contents from disk.
  #
  # Sets the buffer's content to the cached disk contents
  reload: (clearHistory=false) ->
    @emitter.emit 'will-reload'
    if clearHistory
      @clearUndoStack()
      @setTextInRange(@getRange(), @cachedDiskContents ? "", normalizeLineEndings: false, undo: 'skip')
    else
      @setTextViaDiff(@cachedDiskContents)
    @emitModifiedStatusChanged(false)
    @emitter.emit 'did-reload'

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
    if @file?
      promise = @file.read(flushCache)
    else
      promise = Promise.resolve("")

    promise.then (contents) =>
      @cachedDiskContents = contents
      callback?()

  backUpFileContentsBeforeWriting: ->
    return unless @file.existsSync()

    backupFilePath = @getPath() + '~'

    maxTildes = 10
    while fs.existsSync(backupFilePath)
      if --maxTildes is 0
        throw new Error("Can't create a backup file for #{@getPath()} because files already exist at every candidate path.")
      backupFilePath += '~'

    backupFD = fs.openSync(backupFilePath, 'w')
    fs.writeSync(backupFD, @file.readSync())

    # Ensure backup file contents are really on disk before proceeding
    fs.fdatasyncSync(backupFD)
    fs.closeSync(backupFD)

    # Ensure backup file directory entry is really on disk before proceeding
    #
    # Windows doesn't support syncing on directories so we'll just have to live
    # with less safety on that platform.
    unless process.platform is 'win32'
      try
        backupDirectoryFD = fs.openSync(path.dirname(backupFilePath), 'r')
        fs.fdatasyncSync(backupDirectoryFD)
        fs.closeSync(backupDirectoryFD)
      catch error
        console.warn("Non-fatal error syncing parent directory of backup file #{backupFilePath}")

    backupFilePath

  removeBackupFileAfterWriting: (backupFilePath) ->
    # Ensure new file contents are really on disk before proceeding
    fd = fs.openSync(@getPath(), 'a')
    fs.fdatasyncSync(fd)
    fs.closeSync(fd)

    fs.removeSync(backupFilePath)

  ###
  Section: Private Utility Methods
  ###

  loadSync: ->
    @updateCachedDiskContentsSync()
    @finishLoading()

  load: ->
    @updateCachedDiskContents().then => @finishLoading()

  finishLoading: ->
    if @isAlive()
      @loaded = true
      if @digestWhenLastPersisted is @file?.getDigestSync()
        @emitModifiedStatusChanged(@isModified())
      else
        @reload(true)
    this

  destroy: ->
    unless @destroyed
      @cancelStoppedChangingTimeout()
      @fileSubscriptions?.dispose()
      @destroyed = true
      @emitter.emit 'did-destroy'

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
      # contents updated asynchrounously multiple `conflict` events could trigger for the same disk
      # contents.
      @updateCachedDiskContentsSync()
      return if previousContents == @cachedDiskContents

      if @conflict
        @emitter.emit 'did-conflict'
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

    @fileSubscriptions.add @file.onWillThrowWatchError (errorObject) =>
      @emitter.emit 'will-throw-watch-error', errorObject

  createMarkerSnapshot: ->
    snapshot = {}
    for markerLayerId, markerLayer of @markerLayers
      if markerLayer.maintainHistory
        snapshot[markerLayerId] = markerLayer.createSnapshot()
    snapshot

  restoreFromMarkerSnapshot: (snapshot) ->
    for markerLayerId, layerSnapshot of snapshot
      @markerLayers[markerLayerId]?.restoreFromSnapshot(layerSnapshot)

  emitMarkerChangeEvents: (snapshot) ->
    for markerLayerId, markerLayer of @markerLayers
      markerLayer.emitChangeEvents(snapshot?[markerLayerId])

  emitDidChangeTextEvent: (patch) ->
    @emitter.emit 'did-change-text', {changes: Object.freeze(normalizePatchChanges(patch.getChanges()))}
    @patchesSinceLastStoppedChangingEvent.push(patch)
    @scheduleDidStopChangingEvent()

  # Identifies if the buffer belongs to multiple editors.
  #
  # For example, if the {EditorView} was split.
  #
  # Returns a {Boolean}.
  hasMultipleEditors: -> @refcount > 1

  cancelStoppedChangingTimeout: ->
    clearTimeout(@stoppedChangingTimeout) if @stoppedChangingTimeout

  scheduleDidStopChangingEvent: ->
    @cancelStoppedChangingTimeout()
    stoppedChangingCallback = =>
      @stoppedChangingTimeout = null
      modifiedStatus = @isModified()
      @emitter.emit 'did-stop-changing', {changes: Object.freeze(normalizePatchChanges(Patch.compose(@patchesSinceLastStoppedChangingEvent).getChanges()))}
      @patchesSinceLastStoppedChangingEvent = []
      @emitModifiedStatusChanged(modifiedStatus)
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  emitModifiedStatusChanged: (modifiedStatus) ->
    return if modifiedStatus is @previousModifiedStatus
    @previousModifiedStatus = modifiedStatus
    @emitter.emit 'did-change-modified', modifiedStatus

  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row)
      console.log row, line, line.length
    return

  ###
  Section: Private History Delegate Methods
  ###

  invertChange: (change) ->
    Object.freeze({
      oldRange: change.newRange
      newRange: change.oldRange
      oldText: change.newText
      newText: change.oldText
    })

  serializeChange: (change) ->
    {
      oldRange: change.oldRange.serialize()
      newRange: change.newRange.serialize()
      oldText: change.oldText
      newText: change.newText
    }

  deserializeChange: (change) ->
    {
      oldRange: Range.deserialize(change.oldRange)
      newRange: Range.deserialize(change.newRange)
      oldText: change.oldText
      newText: change.newText
    }

  serializeSnapshot: (snapshot, options) ->
    return unless options.markerLayers

    MarkerLayer.serializeSnapshot(snapshot)

  deserializeSnapshot: (snapshot) ->
    MarkerLayer.deserializeSnapshot(snapshot)

  ###
  Section: Private MarkerLayer Delegate Methods
  ###

  markerLayerDestroyed: (markerLayer) ->
    delete @markerLayers[markerLayer.id]

  markerCreated: (layer, marker) ->
    if layer is @defaultMarkerLayer
      @emitter.emit 'did-create-marker', marker

  markersUpdated: (layer) ->
    if layer is @defaultMarkerLayer
      @emitter.emit 'did-update-markers'

  getNextMarkerId: -> @nextMarkerId++
