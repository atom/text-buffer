Random = require "random-seed"
Point = require "../src/point"
Patch = require "../src/patch"
{currentSpecFailed} = require "./spec-helper"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "::regions()", ->
    expectRegions = (iterator, regions) ->
      for [inputPosition, outputPosition, value], i in regions
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

        iterator = patch.regions()

        iterator.seek(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual Point(0, 3)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectRegions iterator, [
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
        expectRegions iterator, [
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
        expectRegions iterator, [
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

        iterator = patch.regions()

        iterator.seekToInputPosition(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual(Point(0, 3))
        expect(iterator.getOutputPosition()).toEqual(Point(0, 3))
        expectRegions iterator, [
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
        expectRegions iterator, [
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

    describe "::splice(oldOutputExtent, newOutputExtent, content)", ->
      it "can insert a single change", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert two disjoint changes", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 12)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectRegions iterator, [
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert three disjoint changes", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 11)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 15)).splice(Point(0, 3), Point(0, 2), "hi")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectRegions patch.regions(), [
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
        expectRegions iterator, [
          [Point(0, 11), Point(0, 12), null]
          [Point(0, 15), Point(0, 15), "efg"]
          [Point(0, 16), Point(0, 16), null]
          [Point(0, 19), Point(0, 18), "hi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can perform a single deletion", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 5), ""]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can delete the start of an existing change", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 8), Point(0, 5), "abcde")
        iterator.seek(Point(0, 3)).splice(Point(0, 6), Point(0, 0), "")

        expectRegions patch.regions(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 13), Point(0, 4), "e"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 3)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectRegions iterator, [
          [Point(0, 13), Point(0, 4), "e"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change within a change", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 3)).splice(Point(0, 5), Point(0, 8), "abcdefgh")
        iterator.seek(Point(0, 4)).splice(Point(0, 2), Point(0, 3), "ijk")

        expectRegions patch.regions(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 12), "aijkdefgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 7)
        expect(iterator.getOutputPosition()).toEqual Point(0, 7)
        expectRegions iterator, [
          [Point(0, 8), Point(0, 12), "defgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 4)).splice(Point(0, 3), Point(0, 1), "l")

        expectRegions patch.regions(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 10), "aldefgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectRegions iterator, [
          [Point(0, 8), Point(0, 10), "defgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that overlaps the end of an existing change", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "efghi")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 11), Point(0, 13), "abcefghi"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 13)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 9)).splice(Point(0, 6), Point(0, 3), "jkl")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 13), Point(0, 12), "abcejkl"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 13)
        expect(iterator.getOutputPosition()).toEqual Point(0, 12)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that overlaps the start of an existing change", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "abcde")

        iterator.seek(Point(0, 5)).splice(Point(0, 5), Point(0, 3), "fgh")
        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 12), Point(0, 11), "fghcde"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 8)
        expectRegions iterator, [
          [Point(0, 12), Point(0, 11), "cde"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "can insert a change that joins two existing changes", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 12)).splice(Point(0, 3), Point(0, 4), "efgh")
        iterator.seek(Point(0, 7)).splice(Point(0, 7), Point(0, 4), "ijkl")

        expectRegions patch.regions(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 14), Point(0, 13), "abijklgh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 11)
        expectRegions iterator, [
          [Point(0, 14), Point(0, 13), "gh"]
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "deletes changes that are reverted", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectRegions patch.regions(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        iterator.seek(Point(0, 0)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 0)).splice(Point(0, 3), Point(0, 0), "")

        expectRegions patch.regions(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

      it "does nothing if both ranges are empty", ->
        iterator = patch.regions()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 0), "")

        expectRegions patch.regions(), [
          [Point.INFINITY, Point.INFINITY, null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectRegions iterator, [
          [Point.INFINITY, Point.INFINITY, null]
        ]

  describe "::changes()", ->
    it "yields change objects that summarize the patch's aggregated changes", ->
      changes = patch.changes()
      expect(changes.next()).toEqual {done: true, value: null}

      iterator = patch.regions()
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

      inputPosition = iterator.getInputPosition()
      minInputPosition = patch.toInputPosition(position)
      maxInputPosition = patch.toInputPosition(position.traverse([0, 1]))
      expect(inputPosition.compare(minInputPosition)).not.toBeLessThan(0)
      expect(inputPosition.compare(maxInputPosition)).not.toBeGreaterThan(0)

      lastNode = null
      for {node, childIndex, outputOffset, inputOffset} in iterator.path by -1
        if lastNode?
          expectedInputOffset = expectedOutputOffset = Point.ZERO
          for child, i in node.children
            break if i is childIndex
            expectedInputOffset = expectedInputOffset.traverse(child.inputExtent)
            expectedOutputOffset = expectedOutputOffset.traverse(child.outputExtent)

          expect(node.children[childIndex]).toBe lastNode
          expect(inputOffset).toEqual expectedInputOffset
          expect(outputOffset).toEqual expectedOutputOffset
        lastNode = node
      expect(lastNode).toBe patch.rootNode

    expectCorrectHunkMerging = (patch) ->
      lastHunkWasChange = null
      iterator = patch.regions()
      until (next = iterator.next()).done
        hunkIsChange = next.value?
        if lastHunkWasChange?
          expect(hunkIsChange).toBe not lastHunkWasChange
        lastHunkWasChange = hunkIsChange

    expectCorrectInternalNodes = (node) ->
      if node.children?
        expectedInputExtent = expectedOutputExtent = Point.ZERO
        for child in node.children
          expectedInputExtent = expectedInputExtent.traverse(child.inputExtent)
          expectedOutputExtent = expectedOutputExtent.traverse(child.outputExtent)
          expectCorrectInternalNodes(child)
        expect(node.inputExtent).toEqual expectedInputExtent
        expect(node.outputExtent).toEqual expectedOutputExtent

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

          iterator = patch.regions()
          iterator.seek(position).splice(oldExtent, newExtent, content)
          reference = spliceString(reference, position, oldExtent, newExtent, content)

          expectCorrectChanges(input, patch, reference)
          expectValidIterator(patch, iterator, position.traverse(newExtent))
          expectCorrectHunkMerging(patch)
          expectCorrectInternalNodes(patch.rootNode)

          if currentSpecFailed()
            console.log ""
            console.log "Seed: #{seed}"
            console.log patch.rootNode.toString()
            return
