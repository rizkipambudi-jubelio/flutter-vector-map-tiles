import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/plugin_api.dart';
import 'package:vector_map_tiles/src/grid/debounce.dart';
import 'package:vector_map_tiles/src/grid/renderer_pipeline.dart';
import '../cache/caches.dart';
import 'disposable_state.dart';
import '../options.dart';
import '../tile_identity.dart';
import 'tile_widgets.dart';

class VectorTileLayer extends StatefulWidget {
  final VectorTileLayerOptions options;
  final MapState mapState;
  final Stream<Null> stream;

  const VectorTileLayer(this.options, this.mapState, this.stream);

  @override
  State<StatefulWidget> createState() {
    return _VectorTileLayerState();
  }
}

class _VectorTileLayerState extends DisposableState<VectorTileLayer>
    with WidgetsBindingObserver {
  StreamSubscription<Null>? _subscription;
  late TileWidgets _tileWidgets;
  late Caches _caches;

  MapState get _mapState => widget.mapState;
  double get _clampedZoom => _mapState.zoom.roundToDouble();
  double _paintZoomScale = 1.0;
  late final _cacheStats = ScheduledDebounce(
      _printCacheStats, Duration(seconds: 1), Duration(seconds: 3));

  @override
  void initState() {
    super.initState();
    _createCaches();
    Future.delayed(Duration(seconds: 3), () {
      _caches.applyConstraints();
    });
    _createTileWidgets();
    _subscription = widget.stream.listen((event) {
      _update();
    });
    _update();
  }

  @override
  void dispose() {
    super.dispose();
    _caches.dispose();
    _subscription?.cancel();
  }

  @override
  void didHaveMemoryPressure() {
    _caches.didHaveMemoryPressure();
  }

  @override
  void didUpdateWidget(covariant VectorTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options.theme.id != widget.options.theme.id) {
      setState(() {
        _caches.dispose();
        _createCaches();
        _createTileWidgets();
        _updateTiles();
      });
    }
  }

  void _createTileWidgets() {
    _tileWidgets = TileWidgets(
        widget.options.tileProvider,
        () => _paintZoomScale,
        () => _mapState.zoom,
        widget.options.theme,
        _caches,
        widget.options.renderMode,
        widget.options.showTileDebugInfo);
  }

  void _createCaches() {
    _caches = Caches(
        provider: widget.options.tileProvider,
        pipeline: RendererPipeline(widget.options.theme,
            scale: widget.options.rasterImageScale),
        ttl: widget.options.fileCacheTtl,
        maxImagesInMemory: widget.options.maxImagesInMemory,
        maxSizeInBytes: widget.options.fileCacheMaximumSizeInBytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_tileWidgets.all.isEmpty) {
      return Container();
    }
    _updatePaintZoomScale();
    final state = _TilePositioningState(_paintZoomScale, _mapState);
    final tileWidgets = _tileWidgets.all.entries
        .map((entry) => _positionTile(state, entry.key, entry.value))
        .toList();
    return Stack(children: tileWidgets);
  }

  void _update() {
    if (disposed) {
      return;
    }
    setState(() {
      _updateTiles();
    });
  }

  void _updateTiles() {
    final center = _mapState.center;
    final pixelBounds = _tiledPixelBounds(center);
    final tileRange = _pixelBoundsToTileRange(pixelBounds);
    final tiles = _expand(tileRange);
    _tileWidgets.update(tiles);
    if (widget.options.logCacheStats) {
      _cacheStats.update();
    }
  }

  Bounds _tiledPixelBounds(LatLng center) {
    var scale = _mapState.getZoomScale(_mapState.zoom, _clampedZoom);
    var centerPoint = _mapState.project(center, _clampedZoom).floor();
    var halfSize = _mapState.size / (scale * 2);

    return Bounds(centerPoint - halfSize, centerPoint + halfSize);
  }

  Bounds _pixelBoundsToTileRange(Bounds bounds) => Bounds(
        bounds.min.unscaleBy(_tileSize).floor(),
        bounds.max.unscaleBy(_tileSize).ceil() - const CustomPoint(1, 1),
      );

  List<TileIdentity> _expand(Bounds range) {
    final zoom = _clampedZoom;
    final tiles = <TileIdentity>[];
    for (num x = range.min.x; x <= range.max.x; ++x) {
      for (num y = range.min.y; y <= range.max.y; ++y) {
        if (x.toInt() >= 0 && y.toInt() >= 0) {
          tiles.add(TileIdentity(zoom.toInt(), x.toInt(), y.toInt()));
        }
      }
    }
    return tiles;
  }

  Widget _positionTile(
      _TilePositioningState state, TileIdentity tile, Widget tileWidget) {
    final tilePosition =
        (tile.scaleBy(_tileSize) - state.origin).multiplyBy(state.zoomScale) +
            state.translate;
    return Positioned(
        key: Key('PositionedGridTile_${tile.z}_${tile.x}_${tile.y}'),
        top: tilePosition.y.toDouble(),
        left: tilePosition.x.toDouble(),
        width: (_tileSize.x * state.zoomScale),
        height: (_tileSize.y * state.zoomScale),
        child: tileWidget);
  }

  double _zoomScale(double mapZoom, double tileZoom) {
    final crs = _mapState.options.crs;
    return crs.scale(mapZoom) / crs.scale(tileZoom);
  }

  void _updatePaintZoomScale() {
    final tileZoom = _tileWidgets.all.keys.first.z;
    _paintZoomScale = _zoomScale(_mapState.zoom, tileZoom.toDouble());
  }

  void _printCacheStats() {
    print('Cache stats:\n${_caches.stats()}');
  }
}

final _tileSize = CustomPoint(256, 256);

class _TilePositioningState {
  final double zoomScale;
  late final CustomPoint<num> origin;
  late final CustomPoint<num> translate;

  _TilePositioningState(this.zoomScale, MapState mapState) {
    final pixelOrigin =
        mapState.getNewPixelOrigin(mapState.center, mapState.zoom).round();
    origin = mapState.project(mapState.unproject(pixelOrigin), mapState.zoom);
    translate = origin.multiplyBy(zoomScale) - pixelOrigin;
  }
}