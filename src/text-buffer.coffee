{Emitter, CompositeDisposable, Disposable} = require 'event-kit'
{File} = require 'pathwatcher'
diff = require 'diff'
_ = require 'underscore-plus'
fs = require 'fs-plus'
path = require 'path'
crypto = require 'crypto'
{BufferOffsetIndex, Patch} = require 'superstring'
Point = require './point'
Range = require './range'
History = require './history'
MarkerLayer = require './marker-layer'
MatchIterator = require './match-iterator'
DisplayLayer = require './display-layer'
{spliceArray, newlineRegex, normalizePatchChanges, regexIsSingleLine} = require './helpers'
{traversal} = require './point-helpers'

class TransactionAbortedError extends Error
  constructor: -> super

# Extended: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
#
# ## Working With Aggregated Changes
#
# When observing changes to the buffer's textual content, it is important to use
# change-aggregating methods such as {::onDidChangeText}, {::onDidStopChanging},
# and {::getChangesSinceCheckpoint} in order to maintain high performance. These
# methods allows your code to respond to *sets* of changes rather than each
# individual change.
#
# These methods report aggregated buffer updates as arrays of change objects
# containing the following fields: `oldRange`, `newRange`, `oldText`, and
# `newText`. The `oldText`, `newText`, and `newRange` fields are
# self-explanatory, but the interepretation of `oldRange` is more nuanced:
#
# The reported `oldRange` is the range of the replaced text in the original
# contents of the buffer *irrespective of the spatial impact of any other
# reported change*. So, for example, if you wanted to apply all the changes made
# in a transaction to a clone of the observed buffer, the easiest approach would
# be to apply the changes in reverse:
#
# ```js
# buffer1.onDidChangeText(({changes}) => {
#   for (const {oldRange, newText} of changes.reverse()) {
#     buffer2.setTextInRange(oldRange, newText)
#   }
# })
#
# If you needed to apply the changes in the forwards order, you would need to
# incorporate the impact of preceding changes into the range passed to
# {::setTextInRange}, as follows:
#
# ```js
# buffer1.onDidChangeText(({changes}) => {
#   for (const {oldRange, newRange, newText} of changes) {
#     const rangeToReplace = Range(
#       newRange.start,
#       newRange.start.traverse(oldRange.getExtent())
#     )
#     buffer2.setTextInRange(rangeToReplace, newText)
#   }
# })
# ```
module.exports =
class TextBuffer
  @version: 5
  @Point: Point
  @Range: Range
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
  #   * `shouldDestroyOnFileDelete` A {Function} that returns a {Boolean}
  #     indicating whether the buffer should be destroyed if its file is
  #     deleted.
  constructor: (params) ->
    text = params if typeof params is 'string'

    @emitter = new Emitter
    @patchesSinceLastStoppedChangingEvent = []
    @id = params?.id ? crypto.randomBytes(16).toString('hex')
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new BufferOffsetIndex()
    @textDecorationLayers = new Set()
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', normalizeLineEndings: false)
    maxUndoEntries = params?.maxUndoEntries ? @defaultMaxUndoEntries
    @history = params?.history ? new History(this, maxUndoEntries)
    @nextMarkerLayerId = params?.nextMarkerLayerId ? 0
    @nextDisplayLayerId = params?.nextDisplayLayerId ? 0
    @defaultMarkerLayer = params?.defaultMarkerLayer ? new MarkerLayer(this, String(@nextMarkerLayerId++))
    @displayLayers = {}
    @markerLayers = params?.markerLayers ? {}
    @markerLayers[@defaultMarkerLayer.id] = @defaultMarkerLayer
    @markerLayersWithPendingUpdateEvents = new Set()
    @nextMarkerId = params?.nextMarkerId ? 1

    @setEncoding(params?.encoding)
    @setPreferredLineEnding(params?.preferredLineEnding)

    @loaded = false
    @destroyed = false
    @transactCallDepth = 0
    @digestWhenLastPersisted = params?.digestWhenLastPersisted ? false

    @shouldDestroyOnFileDelete = params?.shouldDestroyOnFileDelete ? -> false

    @setPath(params.filePath) if params?.filePath
    @load() if params?.load

  @deserialize: (params) ->
    return if params.version isnt TextBuffer.prototype.version

    buffer = Object.create(TextBuffer.prototype)
    markerLayers = {}
    for layerId, layerState of params.markerLayers
      markerLayers[layerId] = MarkerLayer.deserialize(buffer, layerState)
    params.markerLayers = markerLayers
    params.defaultMarkerLayer = params.markerLayers[params.defaultMarkerLayerId]
    params.history = History.deserialize(params.history, buffer)
    params.load = true if params.filePath
    TextBuffer.call(buffer, params)
    displayLayers = {}
    for layerId, layerState of params.displayLayers
      displayLayers[layerId] = DisplayLayer.deserialize(buffer, layerState)
    buffer.setDisplayLayers(displayLayers)
    buffer

  # Returns a {String} representing a unique identifier for this {TextBuffer}.
  getId: ->
    @id

  serialize: (options) ->
    options ?= {}
    options.markerLayers ?= true

    markerLayers = {}
    if options.markerLayers
      for id, layer of @markerLayers when layer.persistent
        markerLayers[id] = layer.serialize()

    displayLayers = {}
    for id, layer of @displayLayers
      displayLayers[id] = layer.serialize()

    id: @getId()
    text: @getText()
    defaultMarkerLayerId: @defaultMarkerLayer.id
    markerLayers: markerLayers
    displayLayers: displayLayers
    nextMarkerLayerId: @nextMarkerLayerId
    nextDisplayLayerId: @nextDisplayLayerId
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
  # buffer changes. **You should probably not be using this in packages**.
  #
  # Because observers are invoked synchronously, it's important not to perform
  # any expensive operations via this method. Consider {::onDidStopChanging} to
  # delay expensive operations until after changes stop occurring, or at the
  # very least use {::onDidChangeText} to invoke your callback once *per
  # transaction* rather than *once per change*. This will help prevent
  # performance degredation when users of your package are typing with multiple
  # cursors, and other scenarios in which multiple changes occur within
  # transactions.
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

  # Public: Invoke the given callback synchronously when a transaction finishes
  # with a list of all the changes in the transaction.
  #
  # * `callback` {Function} to be called when a transaction in which textual
  #   changes occurred is completed.
  #   * `event` {Object} with the following keys:
  #     * `changes` {Array} of {Object}s summarizing the aggregated changes
  #       that occurred during the transaction. See *Working With Aggregated
  #       Changes* in the description of the {TextBuffer} class for details.
  #       * `oldRange` The {Range} of the deleted text in the contents of the
  #         buffer as it existed *before* the batch of changes reported by this
  #         event.
  #       * `newRange`: The {Range} of the inserted text in the current contents
  #         of the buffer.
  #       * `oldText`: A {String} representing the deleted text.
  #       * `newText`: A {String} representing the ineserted text.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
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
  # synchronously, use {::onDidChangeText} instead.
  #
  # * `callback` {Function} to be called when the buffer stops changing.
  #   * `event` {Object} with the following keys:
  #     * `changes` An {Array} containing {Object}s summarizing the aggregated
  #       changes. See *Working With Aggregated Changes* in the description of
  #       the {TextBuffer} class for details.
  #       * `oldRange` The {Range} of the deleted text in the contents of the
  #         buffer as it existed *before* the batch of changes reported by this
  #         event.
  #       * `newRange`: The {Range} of the inserted text in the current contents
  #         of the buffer.
  #       * `oldText`: A {String} representing the deleted text.
  #       * `newText`: A {String} representing the ineserted text.
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
        return @getText() isnt @cachedDiskContents

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
    return if filePath is @getPath()

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
    return null if startRow is 0

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
    return if currentText is text

    endsWithNewline = (str) ->
      /[\r\n]+$/g.test(str)

    computeBufferColumn = (str) ->
      newlineIndex = Math.max(str.lastIndexOf('\n'), str.lastIndexOf('\r'))
      if endsWithNewline(str)
        0
      else if newlineIndex is -1
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
        # Using change.count does not account for lone carriage-returns
        lineCount = change.value.match(newlineRegex)?.length ? 0
        currentPosition[0] = row
        currentPosition[1] = column

        if change.added
          row += lineCount
          column = computeBufferColumn(change.value)
          @setTextInRange([currentPosition, currentPosition], change.value, changeOptions)

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
    change = {
      oldStart: oldRange.start,
      newStart: oldRange.start,
      oldEnd: oldRange.end,
      oldText,
      newText,
      normalizeLineEndings
    }
    @applyChange(change, undo isnt 'skip')

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
  applyChange: (change, pushToHistory = false) ->
    {newStart, oldStart, oldEnd, oldText, newText, normalizeLineEndings} = change
    @cachedText = null

    oldExtent = traversal(oldEnd, oldStart)
    start = Point.fromObject(newStart)
    oldRange = Range(start, start.traverse(oldExtent))
    oldRange.freeze()
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

    newExtent = Point(lines.length - 1, lastLine.length)
    newRange = Range(start, start.traverse(newExtent))
    newRange.freeze()

    if pushToHistory
      change.oldExtent ?= oldExtent
      change.newExtent ?= newExtent
      @history?.pushChange(change)

    newText = normalizedNewText
    changeEvent = Object.freeze({oldRange, newRange, oldText, newText})
    for id, displayLayer of @displayLayers
      displayLayer.bufferWillChange(changeEvent)
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
    if @lines.length > 1 or @lines[0].length > 0
      spliceArray(@lines, startRow, rowCount, lines)
      spliceArray(@lineEndings, startRow, rowCount, lineEndings)
    else
      @lines = lines
      @lineEndings = lineEndings

    # Update the offset index for position <-> character offset translation
    @offsetIndex.splice(startRow, rowCount, lines.map((line, i) -> line.length + lineEndings[i].length))

    if @markerLayers?
      oldExtent = oldRange.getExtent()
      newExtent = newRange.getExtent()
      for id, markerLayer of @markerLayers
        markerLayer.splice(oldRange.start, oldExtent, newExtent)

    @conflict = false if @conflict and not @isModified()

    @changeCount++
    @emitDidChangeEvent(changeEvent)
    newRange

  emitDidChangeEvent: (changeEvent) ->
    # Emit the change event on all the registered text decoration layers.
    @textDecorationLayers.forEach (textDecorationLayer) ->
      textDecorationLayer.bufferDidChange(changeEvent)
    # Emit the change event on all the registered display layers.
    changeEventsByDisplayLayer = new Map()
    for id, displayLayer of @displayLayers
      event = displayLayer.bufferDidChange(changeEvent)
      changeEventsByDisplayLayer.set(displayLayer, event)
    # Emit a normal `did-change` event for other subscribers too.
    @emitter.emit 'did-change', changeEvent
    # Emit a `did-change-sync` event from all the registered display layers.
    changeEventsByDisplayLayer.forEach (event, displayLayer) ->
      displayLayer.emitDidChangeSyncEvent(event)
    # Emit a `did-update` event from all the registered marker layers. If this
    # happens inside a nested transaction, the event will be emitted at the end
    # of the outermost transaction.
    if @markerLayers?
      for id, markerLayer of @markerLayers
        @markersUpdated(markerLayer)

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

  # Public: Create a layer to contain a set of related markers.
  #
  # * `options` An object contaning the following keys:
  #   * `maintainHistory` A {Boolean} indicating whether or not the state of
  #     this layer should be restored on undo/redo operations. Defaults to
  #     `false`.
  #   * `persistent` A {Boolean} indicating whether or not this marker layer
  #     should be serialized and deserialized along with the rest of the
  #     buffer. Defaults to `false`. If `true`, the marker layer's id will be
  #     maintained across the serialization boundary, allowing you to retrieve
  #     it via {::getMarkerLayer}.
  #
  # Returns a {MarkerLayer}.
  addMarkerLayer: (options) ->
    layer = new MarkerLayer(this, String(@nextMarkerLayerId++), options)
    @markerLayers[layer.id] = layer
    layer

  # Public: Get a {MarkerLayer} by id.
  #
  # * `id` The id of the marker layer to retrieve.
  #
  # Returns a {MarkerLayer} or `undefined` if no layer exists with the given
  # id.
  getMarkerLayer: (id) ->
    @markerLayers[id]

  # Public: Get the default {MarkerLayer}.
  #
  # All marker APIs not tied to an explicit layer interact with this default
  # layer.
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
  #   * `exclusive` {Boolean} indicating whether insertions at the start or end
  #     of the marked range should be interpreted as happening *outside* the
  #     marker. Defaults to `false`, except when using the `inside`
  #     invalidation strategy or when when the marker has no tail, in which
  #     case it defaults to true. Explicitly assigning this option overrides
  #     behavior in all circumstances.
  #
  # Returns a {Marker}.
  markRange: (range, properties) -> @defaultMarkerLayer.markRange(range, properties)

  # Public: Create a marker at the given position with no tail in the default
  # marker layer.
  #
  # * `position` {Point} or point-compatible {Array}
  # * `options` (optional) An {Object} with the following keys:
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
  #   * `exclusive` {Boolean} indicating whether insertions at the start or end
  #     of the marked range should be interpreted as happening *outside* the
  #     marker. Defaults to `false`, except when using the `inside`
  #     invalidation strategy or when when the marker has no tail, in which
  #     case it defaults to true. Explicitly assigning this option overrides
  #     behavior in all circumstances.
  #
  # Returns a {Marker}.
  markPosition: (position, options) -> @defaultMarkerLayer.markPosition(position, options)

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
      @applyChange(change) for change in pop.patch.getHunks()
      @restoreFromMarkerSnapshot(pop.snapshot)
      @emitMarkerChangeEvents(pop.snapshot)
      @emitDidChangeTextEvent(pop.patch)
      true
    else
      false

  # Public: Redo the last operation
  redo: ->
    if pop = @history.popRedoStack()
      @applyChange(change) for change in pop.patch.getHunks()
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
    global.atom?.assert compactedChanges, "groupChangesSinceCheckpoint() returned false.", (error) =>
      error.metadata = {history: @history.toString()}
    @history.applyGroupingInterval(groupingInterval)
    @history.enforceUndoStackSizeLimit()
    @emitMarkerChangeEvents(endMarkerSnapshot)
    @emitDidChangeTextEvent(compactedChanges) if compactedChanges
    result

  abortTransaction: ->
    throw new TransactionAbortedError("Transaction aborted.")

  # Public: Clear the undo stack. When calling this method within a transaction,
  # the {::onDidChangeText} event will not be triggered because the information
  # describing the changes is lost.
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
      @applyChange(change) for change in truncated.patch.getHunks()
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

  # Public: Returns a list of changes since the given checkpoint.
  #
  # If the given checkpoint is no longer present in the undo history, this
  # method will return an empty {Array}.
  #
  # Returns an {Array} of {Object}s with the following fields that summarize
  #  the aggregated changes since the checkpoint. See *Working With Aggregated
  # Changes* in the description of the {TextBuffer} class for details.
  # * `oldRange` The {Range} of the deleted text in the text as it existed when
  #   the checkpoint was created.
  # * `newRange`: The {Range} of the inserted text in the current text.
  # * `oldText`: A {String} representing the deleted text.
  # * `newText`: A {String} representing the ineserted text.
  getChangesSinceCheckpoint: (checkpoint) ->
    if patch = @history.getChangesSinceCheckpoint(checkpoint)
      normalizePatchChanges(patch.getHunks())
    else
      []

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
  # * `options` (optional) {Object}
  #   * `leadingContextLineCount` {Number} default `0`; The number of lines before the
  #      matched line to include in the results object.
  #   * `trailingContextLineCount` {Number} default `0`; The number of lines after the
  #      matched line to include in the results object.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  #   * `leadingContextLines` An {Array} with `leadingContextLineCount` lines before the match.
  #   * `trailingContextLines` An {Array} with `trailingContextLineCount` lines after the match.
  scan: (regex, options={}, iterator) ->
    if _.isFunction(options)
      iterator = options
      options = {}

    @scanInRange(regex, @getRange(), options, iterator)

  # Public: Scan regular expression matches in the entire buffer in reverse
  # order, calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `options` (optional) {Object}
  #   * `leadingContextLineCount` {Number} default `0`; The number of lines before the
  #      matched line to include in the results object.
  #   * `trailingContextLineCount` {Number} default `0`; The number of lines after the
  #      matched line to include in the results object.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  #   * `leadingContextLines` An {Array} with `leadingContextLineCount` lines before the match.
  #   * `trailingContextLines` An {Array} with `trailingContextLineCount` lines after the match.
  backwardsScan: (regex, options={}, iterator) ->
    if _.isFunction(options)
      iterator = options
      options = {}

    @backwardsScanInRange(regex, @getRange(), options, iterator)

  # Public: Scan regular expression matches in a given range , calling the given
  # iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `options` (optional) {Object}
  #   * `leadingContextLineCount` {Number} default `0`; The number of lines before the
  #      matched line to include in the results object.
  #   * `trailingContextLineCount` {Number} default `0`; The number of lines after the
  #      matched line to include in the results object.
  # * `callback` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  #   * `leadingContextLines` An {Array} with `leadingContextLineCount` lines before the match.
  #   * `trailingContextLines` An {Array} with `trailingContextLineCount` lines after the match.
  scanInRange: (regex, range, options={}, callback, reverse=false) ->
    if _.isFunction(options)
      reverse = callback
      callback = options
      options = {}

    range = @clipRange(range)
    global = regex.global
    flags = "gm"
    flags += "i" if regex.ignoreCase
    regex = new RegExp(regex.source, flags)

    if regexIsSingleLine(regex)
      if reverse
        iterator = new MatchIterator.BackwardsSingleLine(this, regex, range, options)
      else
        iterator = new MatchIterator.ForwardsSingleLine(this, regex, range, options)
    else
      if reverse
        iterator = new MatchIterator.BackwardsMultiLine(this, regex, range, @backwardsScanChunkSize, options)
      else
        iterator = new MatchIterator.ForwardsMultiLine(this, regex, range, options)

    iterator.iterate(callback, global)

  # Public: Scan regular expression matches in a given range in reverse order,
  # calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `options` (optional) {Object}
  #   * `leadingContextLineCount` {Number} default `0`; The number of lines before the
  #      matched line to include in the results object.
  #   * `trailingContextLineCount` {Number} default `0`; The number of lines after the
  #      matched line to include in the results object.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  backwardsScanInRange: (regex, range, options={}, iterator) ->
    if _.isFunction(options)
      iterator = options
      options = {}

    @scanInRange regex, range, options, iterator, true

  # Public: Replace all regular expression matches in the entire buffer.
  #
  # * `regex` A {RegExp} representing the matches to be replaced.
  # * `replacementText` A {String} representing the text to replace each match.
  #
  # Returns a {Number} representing the number of replacements made.
  replace: (regex, replacementText) ->
    doSave = not @isModified()
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
    @characterIndexForPosition(Point.INFINITY)

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
    position = @clipPosition(Point.fromObject(position))
    @offsetIndex.characterIndexForPosition(position)

  # Public: Convert an absolute character offset, inclusive of newlines, to a
  # position in the buffer in row/column coordinates.
  #
  # The offset is clipped prior to translating.
  #
  # * `offset` A {Number}.
  #
  # Returns a {Point}.
  positionForCharacterIndex: (offset) ->
    position = @offsetIndex.positionForCharacterIndex(Math.max(0, offset))
    new Point(position.row, position.column)

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
  clipPosition: (position, options) ->
    position = Point.fromObject(position)
    Point.assertValid(position)
    {row, column} = position
    if row < 0
      @getFirstPosition()
    else if row > @getLastRow()
      @getEndPosition()
    else if column < 0
      Point(row, 0)
    else if column >= @lineLengthForRow(row)
      if options?.clipDirection is 'forward' and row < @getLastRow()
        Point(row + 1, 0)
      else
        Point(row, @lineLengthForRow(row))
    else
      position

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
    if @destroyed then throw new Error("Can't save destroyed buffer")
    unless filePath then throw new Error("Can't save buffer with no file path")

    @emitter.emit 'will-save', {path: filePath}
    @setPath(filePath)

    if options?.backup
      backupFile = @backUpFileContentsBeforeWriting()

    try
      @file.writeSync(@getText())
      if backupFile?
        backupFile.safeRemoveSync()
    catch error
      if backupFile?
        @file.writeSync(backupFile.readSync())
      throw error

    @cachedDiskContents = @getText()
    @conflict = false
    @loaded = true
    @emitModifiedStatusChanged(false)
    @emitter.emit 'did-save', {path: filePath}

  # Public: Reload the buffer's contents from disk.
  #
  # Sets the buffer's content to the cached disk contents
  reload: (clearHistory=false) ->
    return if @destroyed
    @emitter.emit 'will-reload'
    if clearHistory
      @clearUndoStack()
      @setTextInRange(@getRange(), @cachedDiskContents ? "", normalizeLineEndings: false, undo: 'skip')
    else
      @setTextViaDiff(@cachedDiskContents ? "")
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

    file = new File(backupFilePath, false, false)
    file.safeWriteSync(@file.readSync())
    file

  ###
  Section: Display Layers
  ###

  addDisplayLayer: (params) ->
    id = @nextDisplayLayerId++
    @displayLayers[id] = new DisplayLayer(id, this, params)

  getDisplayLayer: (id) ->
    @displayLayers[id]

  setDisplayLayers: (@displayLayers) -> # Used for deserialization

  registerTextDecorationLayer: (textDecorationLayer) ->
    @textDecorationLayers.add(textDecorationLayer)
    new Disposable(=> @textDecorationLayers.delete(textDecorationLayer))

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
      @destroyed = true
      @emitter.emit 'did-destroy'
      @emitter.clear()

      @cancelStoppedChangingTimeout()
      @fileSubscriptions?.dispose()
      for id, markerLayer of @markerLayers
        markerLayer.destroy()
      @setText('', undo: 'skip')
      @history.clear()

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
      # On Linux we get change events when the file is deleted. This yields
      # consistent behavior with Mac/Windows.
      return unless @file.existsSync()

      @conflict = true if @isModified()
      previousContents = @cachedDiskContents

      # Synchrounously update the disk contents because the {File} has already cached them. If the
      # contents updated asynchrounously multiple `conflict` events could trigger for the same disk
      # contents.
      @updateCachedDiskContentsSync()
      return if previousContents is @cachedDiskContents

      if @conflict
        @emitter.emit 'did-conflict'
      else
        @reload()

    @fileSubscriptions.add @file.onDidDelete =>
      modified = @getText() isnt @cachedDiskContents
      @emitter.emit 'did-delete'
      @updateCachedDiskContents()
      if not modified and @shouldDestroyOnFileDelete()
        @destroy()
      else
        @emitModifiedStatusChanged(true)


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
    while @markerLayersWithPendingUpdateEvents.size > 0
      updatedMarkerLayers = Array.from(@markerLayersWithPendingUpdateEvents)
      @markerLayersWithPendingUpdateEvents.clear()
      for markerLayer in updatedMarkerLayers
        markerLayer.emitUpdateEvent()
        if markerLayer is @defaultMarkerLayer
          @emitter.emit 'did-update-markers'

    for markerLayerId, markerLayer of @markerLayers
      markerLayer.emitChangeEvents(snapshot?[markerLayerId])

  emitDidChangeTextEvent: (patch) ->
    return if @transactCallDepth isnt 0

    @emitter.emit 'did-change-text', {changes: Object.freeze(normalizePatchChanges(patch.getHunks()))}
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
      @emitter.emit 'did-stop-changing', {changes: Object.freeze(normalizePatchChanges(Patch.compose(@patchesSinceLastStoppedChangingEvent).getHunks()))}
      @patchesSinceLastStoppedChangingEvent = []
      @emitModifiedStatusChanged(modifiedStatus)
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  emitModifiedStatusChanged: (modifiedStatus) ->
    return if modifiedStatus is @previousModifiedStatus
    @previousModifiedStatus = modifiedStatus
    @emitter.emit 'did-change-modified', modifiedStatus

  logLines: (start = 0, end = @getLastRow()) ->
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
    if @transactCallDepth is 0
      layer.emitUpdateEvent()
      if layer is @defaultMarkerLayer
        @emitter.emit 'did-update-markers'
    else
      @markerLayersWithPendingUpdateEvents.add(layer)

  getNextMarkerId: -> @nextMarkerId++
