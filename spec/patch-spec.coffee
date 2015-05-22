Random = require "random-seed"
Point = require "../src/point"
Patch = require "../src/patch"
{currentSpecFailed} = require "./spec-helper"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "::buildIterator()", ->
    expectHunks = (iterator, hunks) ->
      for [inputPosition, outputPosition, value], i in hunks
        expect(iterator.next()).toEqual {value, done: false}
        expect(iterator.getInputPosition()).toEqual inputPosition, "input position for hunk #{i}"
        expect(iterator.getOutputPosition()).toEqual outputPosition, "output position for hunk #{i}"
        return if currentSpecFailed()

      expect(iterator.next()).toEqual {value: null, done: true}
      expect(iterator.getOutputPosition()).toEqual Point.INFINITY
      expect(iterator.getInputPosition()).toEqual Point.INFINITY

    logTree = ->
      console.log ''
      console.log patch.rootNode.toString()
      console.log ''

    describe "::seek(position)", ->
      it "moves the iterator to the given position in the patch", ->
        patch.splice(Point(0, 5), Point(0, 2), Point(0, 4), "abcd")
        patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
        patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")

        iterator = patch.buildIterator()

        iterator.seek(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual Point(0, 3)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectHunks iterator, [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 7), Point(0, 9), "abcd"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 8))
        expect(iterator.getInputPosition()).toEqual Point(0, 7)
        expect(iterator.getOutputPosition()).toEqual Point(0, 8)
        expectHunks iterator, [
          [Point(0, 7), Point(0, 9), "d"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 13))
        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 13)
        expectHunks iterator, [
          [Point(0, 14), Point(0, 15), "fg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

    describe "::seekToInputPosition(position)", ->
      it "moves the iterator to the given input position in the patch", ->
        patch.splice(Point(0, 5), Point(0, 2), Point(0, 4), "abcd")
        patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
        patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")

        iterator = patch.buildIterator()

        iterator.seekToInputPosition(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual(Point(0, 3))
        expect(iterator.getOutputPosition()).toEqual(Point(0, 3))
        expectHunks iterator, [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 7), Point(0, 9), "abcd"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seekToInputPosition(Point(0, 7))
        expect(iterator.getInputPosition()).toEqual(Point(0, 7))
        expect(iterator.getOutputPosition()).toEqual(Point(0, 9))
        expectHunks iterator, [
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

    describe "::splice(oldOutputExtent, newOutputExtent, content)", ->
      it "can insert a single change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert two disjoint changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 12)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert three disjoint changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 11)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 15)).splice(Point(0, 3), Point(0, 2), "hi")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point(0, 11), Point(0, 12), null]
          [Point(0, 15), Point(0, 15), "efg"]
          [Point(0, 16), Point(0, 16), null]
          [Point(0, 19), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point(0, 11), Point(0, 12), null]
          [Point(0, 15), Point(0, 15), "efg"]
          [Point(0, 16), Point(0, 16), null]
          [Point(0, 19), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can perform a single deletion", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 5), ""]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can delete the start of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 8), Point(0, 5), "abcde")
        iterator.seek(Point(0, 3)).splice(Point(0, 6), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 13), Point(0, 4), "e"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 3)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectHunks iterator, [
          [Point(0, 13), Point(0, 4), "e"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change within a change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 3)).splice(Point(0, 5), Point(0, 8), "abcdefgh")
        iterator.seek(Point(0, 4)).splice(Point(0, 2), Point(0, 3), "ijk")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 12), "aijkdefgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 7)
        expect(iterator.getOutputPosition()).toEqual Point(0, 7)
        expectHunks iterator, [
          [Point(0, 8), Point(0, 12), "defgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 4)).splice(Point(0, 3), Point(0, 1), "l")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 10), "aldefgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point(0, 8), Point(0, 10), "defgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that overlaps the end of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "efghi")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 11), Point(0, 13), "abcefghi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 13)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 9)).splice(Point(0, 6), Point(0, 3), "jkl")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 13), Point(0, 12), "abcejkl"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 13)
        expect(iterator.getOutputPosition()).toEqual Point(0, 12)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that overlaps the start of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "abcde")

        iterator.seek(Point(0, 5)).splice(Point(0, 5), Point(0, 3), "fgh")
        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 12), Point(0, 11), "fghcde"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 8)
        expectHunks iterator, [
          [Point(0, 12), Point(0, 11), "cde"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that joins two existing changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 12)).splice(Point(0, 3), Point(0, 4), "efgh")
        iterator.seek(Point(0, 7)).splice(Point(0, 7), Point(0, 4), "ijkl")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 14), Point(0, 13), "abijklgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 11)
        expectHunks iterator, [
          [Point(0, 14), Point(0, 13), "gh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "deletes hunks for changes that are reverted", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 0)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 0)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "does nothing if both ranges are empty", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

  describe "::toInputPosition() and ::toOutputPosition()", ->
    it "converts between input and output positions", ->
      patch.splice(Point(0, 3), Point(0, 3), Point(0, 5), "abcde")

      expect(patch.toInputPosition(Point(0, 3))).toEqual Point(0, 3)
      expect(patch.toInputPosition(Point(0, 5))).toEqual Point(0, 5)
      expect(patch.toInputPosition(Point(0, 8))).toEqual Point(0, 6)
      expect(patch.toInputPosition(Point(0, 9))).toEqual Point(0, 7)

      expect(patch.toOutputPosition(Point(0, 3))).toEqual Point(0, 3)
      expect(patch.toOutputPosition(Point(0, 5))).toEqual Point(0, 5)
      expect(patch.toOutputPosition(Point(0, 6))).toEqual Point(0, 8)
      expect(patch.toOutputPosition(Point(0, 7))).toEqual Point(0, 9)

  describe "::changes()", ->
    it "yields a sequence of splices that summarize that patch's changes", ->
      changes = patch.changes()
      expect(changes.next()).toEqual {done: true, value: null}

      iterator = patch.buildIterator()
      iterator.seek(Point(0, 12)).splice(Point(0, 4), Point(0, 3), "efg")
      iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

      changes = patch.changes()

      expect(changes.next()).toEqual {
        done: false
        value: {
          position: Point(0, 5),
          oldExtent: Point(0, 3),
          newExtent: Point(0, 4),
          content: "abcd"
        }
      }

      expect(changes.next()).toEqual {
        done: false
        value: {
          position: Point(0, 13),
          oldExtent: Point(0, 4),
          newExtent: Point(0, 3),
          content: "efg"
        }
      }

      expect(changes.next()).toEqual {done: true, value: null}
      expect(changes.next()).toEqual {done: true, value: null}

  describe "random mutation", ->
    LETTERS = Array(10).join("abcdefghijklmnopqrstuvwxyz")
    MAX_INSERT = 10
    MAX_DELETE = 10
    MAX_COLUMNS = 80

    [seed, random] = []

    randomString = (length, upperCase) ->
      result = LETTERS.substr(random(26), length)
      if upperCase
        result.toUpperCase()
      else
        result

    randomSplice = (string) ->
      column = random(string.length)
      switch random(3)
        when 0
          oldCount = random.intBetween(1, Math.min(MAX_DELETE, string.length - column))
          newCount = random.intBetween(1, MAX_INSERT)
        when 1
          oldCount = 0
          newCount = random.intBetween(1, MAX_INSERT)
        when 2
          oldCount = random.intBetween(1, Math.min(MAX_DELETE, string.length - column))
          newCount = 0
      {
        position: Point(0, column),
        oldExtent: Point(0, oldCount),
        newExtent: Point(0, newCount),
        content: randomString(newCount, true)
      }

    spliceString = (input, position, oldExtent, newExtent, content) ->
      chars = input.split('')
      chars.splice(position.column, oldExtent.column, content)
      chars.join('')

    expectCorrectChanges = (input, patch, reference) ->
      patchedInput = input
      changes = patch.changes()
      until (next = changes.next()).done
        {position, oldExtent, newExtent, content} = next.value
        patchedInput = spliceString(patchedInput, position, oldExtent, newExtent, content)
      expect(patchedInput).toBe(reference)

    expectValidIterator = (patch, iterator, position) ->
      expect(iterator.getOutputPosition()).toEqual(position)

      referenceIterator = patch.buildIterator().seek(position, true)
      until (referenceNext = referenceIterator.next()).done

        # For now, seeking an iterator parks it at the left-most input position
        # that matches the given output position, so in order to match the
        # iterator that performed the splice, we have to advance past any pure
        # insertion hunks.
        continue if referenceIterator.getOutputPosition().isEqual(position)

        next = iterator.next()
        expect(next.value).toBe(referenceNext.value)
        expect(iterator.getInputPosition()).toEqual(referenceIterator.getInputPosition())
        expect(iterator.getOutputPosition()).toEqual(referenceIterator.getOutputPosition())
      expect(iterator.next().done).toBe(true)

    it "matches the behavior of mutating text directly", ->
      for i in [1..10]
        seed = Date.now()
        random = new Random(seed)
        input = randomString(random(MAX_COLUMNS))
        reference = input
        patch = new Patch

        for j in [1..50]
          {position, oldExtent, newExtent, content} = randomSplice(reference)

          # console.log "#{j}: #{reference}"
          # console.log "splice(#{position.column}, #{oldExtent.column}, #{newExtent.column}, '#{content}')"

          iterator = patch.buildIterator()
          iterator.seek(position).splice(oldExtent, newExtent, content)
          reference = spliceString(reference, position, oldExtent, newExtent, content)

          expectCorrectChanges(input, patch, reference)
          expectValidIterator(patch, iterator, position.traverse(newExtent))

          if currentSpecFailed()
            console.log ""
            console.log "Seed: #{seed}"
            console.log patch.rootNode.toString()
            return
