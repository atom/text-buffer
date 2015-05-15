# Patch

A data structure for managing text changes.

### Installation

```sh
$ npm install atom-patch
```

### Usage

Create a patch:

```js
var {Point, Patch} = require("atom-patch");
var patch = new Patch;
```

Make a change to the patch:

```js
iterator = patch.buildIterator();
iterator.seekToInputPosition(Point(2, 5));
iterator.splice(Point(0, 3), Point(0, 4), "abcd");
```

Read the patch, hunk by hunk:
```js
iterator.seek(Point(0, 0));

iterator.next();              // => {value: null, done: false}
iterator.getInputPosition();  // => Point(2, 5)
iterator.getOutputPosition(); // => Point(2, 5)

iterator.next();              // => {value: "abcd", done: false}
iterator.getInputPosition();  // => Point(2, 8)
iterator.getOutputPosition(); // => Point(2, 9)

iterator.next();              // => {value: null, done: false}
iterator.getInputPosition();  // => Point(Infinity, Infinity)
iterator.getOutputPosition(); // => Point(Infinity, Infinity)

iterator.next();              // => {value: null, done: true}
```

### License

This module is MIT-Licensed.
