import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../src/rust/api/types.dart';
import 'capture_models.dart';

/// Recorte elegido, normalizado (0..1) respecto a la imagen base ya girada.
class CropChoice {
  const CropChoice(this.rect);
  final CropRect rect;
  bool get isFull => rect.x <= 0.005 && rect.y <= 0.005 && rect.w >= 0.99 && rect.h >= 0.99;
}

/// Diálogo de recorte a pantalla completa con un rectángulo ajustable por las esquinas.
Future<CropChoice?> showCropDialog(BuildContext context, {required CapturePage page}) {
  return Navigator.of(context)
      .push<CropChoice>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CropScreen(page: page)));
}

class _CropScreen extends StatefulWidget {
  const _CropScreen({required this.page});
  final CapturePage page;

  @override
  State<_CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<_CropScreen> {
  late Rect _rect;
  static const _min = 0.08;

  @override
  void initState() {
    super.initState();
    final c = widget.page.crop;
    _rect = c == null ? const Rect.fromLTWH(0, 0, 1, 1) : Rect.fromLTWH(c.x, c.y, c.w, c.h);
  }

  void _drag(int corner, Offset delta, Size size) {
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    var l = _rect.left, t = _rect.top, r = _rect.right, b = _rect.bottom;
    switch (corner) {
      case 0:
        l = (l + dx).clamp(0.0, r - _min);
        t = (t + dy).clamp(0.0, b - _min);
      case 1:
        r = (r + dx).clamp(l + _min, 1.0);
        t = (t + dy).clamp(0.0, b - _min);
      case 2:
        l = (l + dx).clamp(0.0, r - _min);
        b = (b + dy).clamp(t + _min, 1.0);
      case 3:
        r = (r + dx).clamp(l + _min, 1.0);
        b = (b + dy).clamp(t + _min, 1.0);
      default:
        final w = _rect.width, h = _rect.height;
        l = (l + dx).clamp(0.0, 1.0 - w);
        t = (t + dy).clamp(0.0, 1.0 - h);
        r = l + w;
        b = t + h;
    }
    setState(() => _rect = Rect.fromLTRB(l, t, r, b));
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final ratio = page.rotatedBaseHeight == 0 ? 1.0 : page.rotatedBaseWidth / page.rotatedBaseHeight;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Recortar', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => setState(() => _rect = const Rect.fromLTWH(0, 0, 1, 1)),
            child: const Text('Restablecer', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              CropChoice(CropRect(x: _rect.left, y: _rect.top, w: _rect.width, h: _rect.height)),
            ),
            child: const Text(
              'Aplicar',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: LayoutBuilder(
                builder: (ctx, box) {
                  final size = box.biggest;
                  final px = Rect.fromLTRB(
                    _rect.left * size.width,
                    _rect.top * size.height,
                    _rect.right * size.width,
                    _rect.bottom * size.height,
                  );
                  Widget handle(int corner, Offset pos, String label) => Positioned(
                    left: pos.dx - 24,
                    top: pos.dy - 24,
                    child: Semantics(
                      label: 'Esquina $label del recorte',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) => _drag(corner, d.delta, size),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.black54),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: RotatedBox(
                          quarterTurns: page.quarterTurns,
                          child: Image.file(File(page.basePath), fit: BoxFit.fill),
                        ),
                      ),
                      Positioned.fill(child: CustomPaint(painter: _ShadePainter(px))),
                      Positioned.fromRect(
                        rect: px,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanUpdate: (d) => _drag(4, d.delta, size),
                        ),
                      ),
                      handle(0, px.topLeft, 'superior izquierda'),
                      handle(1, px.topRight, 'superior derecha'),
                      handle(2, px.bottomLeft, 'inferior izquierda'),
                      handle(3, px.bottomRight, 'inferior derecha'),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShadePainter extends CustomPainter {
  _ShadePainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(rect),
    );
    canvas.drawPath(shade, Paint()..color = Colors.black54);
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.rect != rect;
}
