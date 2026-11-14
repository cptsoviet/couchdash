import 'dart:math';

import 'package:flutter/material.dart';

/// This traversal policy manage the up and down direction to be totally
/// predictable.
/// Going up or down will always go to the next or previous row. All other
/// traversal policy try to be smart, and in some cases can skip rows when
/// going up or down.
/// CouchDash: focus nodes whose rows wrap on left/right, by group ("apps", "ha-tiles"); each widget adds and removes
/// its own. Wrapping stays inside a group, so the HA tiles cycle among themselves and the app icons among theirs.
final Map<FocusNode, String> wrapGroupOf = {};

class RowByRowTraversalPolicy extends FocusTraversalPolicy with DirectionalFocusTraversalPolicyMixin {
  @override
  Iterable<FocusNode> sortDescendants(Iterable<FocusNode> descendants, FocusNode currentNode) => descendants;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    List<FocusNode>? nodes = currentNode.nearestScope?.traversalDescendants.toList();
    if (nodes == null) {
      return super.inDirection(currentNode, direction);
    }

    NodeSearcher searcher = NodeSearcher(direction);
    List<CandidateNode> candidates = searcher.findCandidates(nodes, currentNode);
    if (candidates.isEmpty) {
      final wrapped = _wrapAppRow(nodes, currentNode, direction);
      if (wrapped != null) {
        wrapped.requestFocus();
        return true;
      }
      return super.inDirection(currentNode, direction);
    }
    FocusNode nextNode = searcher.findBestFocusNode(candidates, currentNode);
    nextNode.requestFocus();
    return true;
  }
}

// CouchDash: right on the last item of a row goes to the first item of the next row (from the last row: the first
// row); left on the first item goes to the last item of the previous row (from the first row: the last row).
FocusNode? _wrapAppRow(List<FocusNode> nodes, FocusNode current, TraversalDirection direction) {
  if (direction != TraversalDirection.left && direction != TraversalDirection.right) return null;
  final group = wrapGroupOf[current];
  if (group == null) return null;
  final rows = <int, List<FocusNode>>{};
  for (final node in nodes.where((n) => wrapGroupOf[n] == group)) {
    rows.putIfAbsent(node.rect.center.dy.round(), () => []).add(node);
  }
  final ys = rows.keys.toList()..sort();
  if (ys.isEmpty) return null;
  final row = ys.indexOf(current.rect.center.dy.round());
  if (row < 0) return null;
  final right = direction == TraversalDirection.right;
  final target = rows[ys[right ? (row + 1) % ys.length : (row - 1 + ys.length) % ys.length]]!
    ..sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
  return right ? target.first : target.last;
}

class NodeSearcher {
  final TraversalDirection directionToSearch;

  NodeSearcher(this.directionToSearch);

  /// should be called first
  List<CandidateNode> findCandidates(List<FocusNode> nodes, FocusNode from) {
    List<FocusNode> copy = List.from(nodes, growable: true);

    switch (directionToSearch) {
      case TraversalDirection.up:
        copy.removeWhere((element) => element.isBelowOrEquals(from));
        break;
      case TraversalDirection.down:
        copy.removeWhere((element) => element.isAboveOrEquals(from));
        break;
      case TraversalDirection.right:
        copy.removeWhere((element) => element.isLeftToOrEquals(from) || !element.isOnTheSameRow(from));
        break;
      case TraversalDirection.left:
        copy.removeWhere((element) => element.isRightToOrEquals(from) || !element.isOnTheSameRow(from));
        break;
    }
    return toCandidateNodes(copy);
  }

  FocusNode findBestFocusNode(List<CandidateNode> nodes, FocusNode from) {
    List<FocusNode> candidates = toFocusNodes(nodes);

    return candidates.reduce((bestNode, challenger) {
      if (directionToSearch == TraversalDirection.down && challenger.isAbove(bestNode)) {
        return challenger;
      } else if (directionToSearch == TraversalDirection.up && challenger.isBelow(bestNode)) {
        return challenger;
      } else if (directionToSearch == TraversalDirection.left && challenger.isRightTo(bestNode)) {
        return challenger;
      } else if (directionToSearch == TraversalDirection.right && challenger.isLeftTo(bestNode)) {
        return challenger;
      }
      // compute the element which is the closest horizontally
      if (challenger.isOnTheSameRow(bestNode) && challenger.distance(from) < bestNode.distance(from)) {
        return challenger;
      }
      return bestNode;
    });
  }
}

/// An internal object to use the [NodeSearcher] class as expected
class CandidateNode {
  final FocusNode node;

  CandidateNode(this.node);
}

/// Some conversion utilities used internally
List<CandidateNode> toCandidateNodes(List<FocusNode> nodes) => nodes.map((e) => CandidateNode(e)).toList();

List<FocusNode> toFocusNodes(List<CandidateNode> nodes) => nodes.map((e) => e.node).toList();

/// A few extension methods to the [FocusNode] to be able to compare their
/// respective position easily.
extension Geometry on FocusNode {
  bool isBelow(FocusNode other) {
    return rect.center.dy.round() > other.rect.center.dy.round();
  }

  bool isBelowOrEquals(FocusNode other) {
    return rect.center.dy.round() >= other.rect.center.dy.round();
  }

  bool isRightTo(FocusNode other) {
    return rect.center.dx.round() > other.rect.center.dx.round();
  }

  bool isRightToOrEquals(FocusNode other) {
    return rect.center.dx.round() >= other.rect.center.dx.round();
  }

  bool isLeftTo(FocusNode other) {
    return rect.center.dx.round() < other.rect.center.dx.round();
  }

  bool isLeftToOrEquals(FocusNode other) {
    return rect.center.dx.round() <= other.rect.center.dx.round();
  }

  bool isAbove(FocusNode other) {
    return rect.center.dy.round() < other.rect.center.dy.round();
  }

  bool isAboveOrEquals(FocusNode other) {
    return rect.center.dy.round() <= other.rect.center.dy.round();
  }

  bool isOnTheSameRow(FocusNode other) {
    return rect.center.dy.round() == other.rect.center.dy.round();
  }

  double distance(FocusNode other) {
    return sqrt(pow(rect.center.dx.round() - other.rect.center.dx.round(), 2) +
        pow(rect.center.dy.round() - other.rect.center.dy.round(), 2));
  }
}
