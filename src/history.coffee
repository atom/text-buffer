Serializable = require 'nostalgia'
Transaction = require './transaction'
BufferPatch = require './buffer-patch'

TransactionAborted = new Error("Transaction Aborted")

module.exports =
class History extends Serializable
  @registerDeserializers(Transaction, BufferPatch)

  currentTransaction: null
  transactionDepth: 0
  transactCallDepth: 0

  constructor: (@buffer, @undoStack=[], @redoStack=[]) ->

  serializeParams: ->
    undoStack: @undoStack.map (patch) -> patch.serialize()
    redoStack: @redoStack.map (patch) -> patch.serialize()

  deserializeParams: (params) ->
    params.undoStack = params.undoStack.map (patchState) => @constructor.deserialize(patchState)
    params.redoStack = params.redoStack.map (patchState) => @constructor.deserialize(patchState)
    params

  recordNewPatch: (patch) ->
    if @currentTransaction?
      @currentTransaction.push(patch)
    else
      @undoStack.push(patch)
    @redoStack.length = 0

  undo: ->
    if @currentTransaction?
      @abortTransaction()
    else if patch = @undoStack.pop()
      inverse = patch.invert(@buffer)
      @redoStack.push(inverse)
      inverse.applyTo(@buffer)

  redo: ->
    if patch = @redoStack.pop()
      inverse = patch.invert(@buffer)
      @undoStack.push(inverse)
      inverse.applyTo(@buffer)

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

  beginTransaction: ->
    if ++@transactionDepth is 1
      @currentTransaction = new Transaction()

  commitTransaction: ->
    if --@transactionDepth is 0
      @undoStack.push(@currentTransaction) if @currentTransaction.hasBufferPatches()
      @currentTransaction = null

  abortTransaction: ->
    if @transactCallDepth is 0
      inverse = @currentTransaction.invert(@buffer)
      @currentTransaction = null
      @transactionDepth = 0
      inverse.applyTo(@buffer)
    else
      throw TransactionAborted

  isTransacting: ->
    @currentTransaction?
