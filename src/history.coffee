Serializable = require 'serializable'
Transaction = require './transaction'
BufferPatch = require './buffer-patch'
{last} = require 'underscore-plus'

TransactionAborted = new Error("Transaction Aborted")

# Manages undo/redo for {TextBuffer}
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

  # Called by {TextBuffer} to store a patch in the undo stack. Clears the redo
  # stack
  recordNewPatch: (patch) ->
    if @currentTransaction?
      @currentTransaction.push(patch)
    else
      @undoStack.push(patch)
    @clearRedoStack()

  undo: ->
    throw new Error("Can't undo with an open transaction") if @currentTransaction?
    if patch = @undoStack.pop()
      inverse = patch.invert(@buffer)
      @redoStack.push(inverse)
      inverse.applyTo(@buffer)

  redo: ->
    throw new Error("Can't redo with an open transaction") if @currentTransaction?
    if patch = @redoStack.pop()
      inverse = patch.invert(@buffer)
      @undoStack.push(inverse)
      inverse.applyTo(@buffer)

  transact: (groupingInterval, fn) ->
    unless fn?
      fn = groupingInterval
      groupingInterval = undefined

    @beginTransaction(groupingInterval)
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

  beginTransaction: (groupingInterval) ->
    if ++@transactionDepth is 1
      @currentTransaction = new Transaction([], groupingInterval)

  commitTransaction: ->
    throw new Error("No transaction is open") unless @transactionDepth > 0

    if --@transactionDepth is 0
      if @currentTransaction.hasBufferPatches()
        lastTransaction = last(@undoStack)
        if @currentTransaction.isOpenForGrouping?() and lastTransaction?.isOpenForGrouping?()
          lastTransaction.merge(@currentTransaction)
        else
          @undoStack.push(@currentTransaction)
      @currentTransaction = null

  abortTransaction: ->
    throw new Error("No transaction is open") unless @transactionDepth > 0

    if @transactCallDepth is 0
      inverse = @currentTransaction.invert(@buffer)
      @currentTransaction = null
      @transactionDepth = 0
      inverse.applyTo(@buffer)
    else
      throw TransactionAborted

  isTransacting: ->
    @currentTransaction?

  clearUndoStack: ->
    @undoStack.length = 0

  clearRedoStack: ->
    @redoStack.length = 0
