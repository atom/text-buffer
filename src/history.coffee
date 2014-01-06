Serializable = require 'serializable'
Transaction = require './transaction'
BufferPatch = require './buffer-patch'

TransactionAborted = new Error("Transaction Aborted")

# Private: Manages undo/redo for {TextBuffer}
module.exports =
class History extends Serializable
  @registerDeserializers(Transaction, BufferPatch)

  currentTransaction: null
  transactionDepth: 0
  transactCallDepth: 0

  constructor: (@buffer, @undoStack=[], @redoStack=[]) ->

  # Private: Used by {Serializable} during serialization
  serializeParams: ->
    undoStack: @undoStack.map (patch) -> patch.serialize()
    redoStack: @redoStack.map (patch) -> patch.serialize()

  # Private: Used by {Serializable} during deserialization
  deserializeParams: (params) ->
    params.undoStack = params.undoStack.map (patchState) => @constructor.deserialize(patchState)
    params.redoStack = params.redoStack.map (patchState) => @constructor.deserialize(patchState)
    params

  # Private: Called by {TextBuffer} to store a patch in the undo stack. Clears
  # the redo stack
  recordNewPatch: (patch) ->
    if @currentTransaction?
      @currentTransaction.push(patch)
    else
      @undoStack.push(patch)
    @clearRedoStack()

  # Public: Undoes the last operation. If a transaction is in progress, aborts it.
  undo: ->
    if @currentTransaction?
      @abortTransaction()
    else if patch = @undoStack.pop()
      inverse = patch.invert(@buffer)
      @redoStack.push(inverse)
      inverse.applyTo(@buffer)

  # Public: Redoes the last operation.
  redo: ->
    if patch = @redoStack.pop()
      inverse = patch.invert(@buffer)
      @undoStack.push(inverse)
      inverse.applyTo(@buffer)

  # Public: Wraps the given function in a transaction, meaning all changes will
  # be undone/redone at the same time. The transaction will be aborted if the
  # function throws an exception. The function's execution will be halted if
  # ::abortTransaction is called.
  transact: (fn) ->
    @beginTransaction()
    try
      ++@transactCallDepth
      result = fn()
      --@transactCallDepth
      @commitTransaction()
      result
    catch error
      if --@transactCallDepth is 0
        @abortTransaction()
        throw error unless error is TransactionAborted
      else
        throw error

  # Public: Starts an open-ended transaction. Call ::commitTransaction or
  # ::abortTransaction to complete it.
  beginTransaction: ->
    if ++@transactionDepth is 1
      @currentTransaction = new Transaction()

  # Public: Commits an outstanding transaction.
  commitTransaction: ->
    if --@transactionDepth is 0
      @undoStack.push(@currentTransaction) if @currentTransaction.hasBufferPatches()
      @currentTransaction = null

  # Public: Aborts an outstanding transaction.
  abortTransaction: ->
    if @transactCallDepth is 0
      inverse = @currentTransaction.invert(@buffer)
      @currentTransaction = null
      @transactionDepth = 0
      inverse.applyTo(@buffer)
    else
      throw TransactionAborted

  # Public: Returns whether the buffer is currently in a transaction.
  isTransacting: ->
    @currentTransaction?

  # Public: Clears the undo stack
  clearUndoStack: ->
    @undoStack.length = 0

  # Public: Clears the redo stack
  clearRedoStack: ->
    @redoStack.length = 0
