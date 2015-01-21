Serializable = require 'serializable'

module.exports =
class Checkpoint extends Serializable
  @registerDeserializers(Checkpoint)
