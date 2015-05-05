setEqual = (a, b) ->
  return false unless a.size is b.size
  iterator = a.values()
  until (next = iterator.next()).done
    return false unless b.has(next.value)
  true

subtractSet = (set, valuesToRemove) ->
  valuesToRemove.forEach (value) -> set.delete(value)

addSet = (set, valuesToAdd) ->
  valuesToAdd.forEach (value) -> set.add(value)

intersectSet = (set, other) ->
  set.forEach (value) -> set.delete(value) unless other.has(value)

module.exports = {setEqual, subtractSet, addSet, intersectSet}
