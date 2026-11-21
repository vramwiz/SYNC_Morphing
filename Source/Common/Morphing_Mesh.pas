
unit Morphing_Mesh;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.Types, Morphing_Model;

function BarycentricPoint(const A, B, C, Weights: TPointF): TPointF;
function Cross(const A, B, C: TPointF): Double;
function Triangulate(const Points: TPointPath): TTriangles;
function ContainsPoint(const Polygon: TPointPath; const P: TPointF): Boolean;
function OutlineDistance(const Polygon: TPointPath; const P: TPointF): Single;

implementation

uses System.Math, System.Generics.Collections;

type
  TEdge = record
    A, B: Integer;
  end;
  TCell = record
    Triangle: TTriangle;
    U, V, RadiusSquared: Double;
  end;

function BarycentricPoint(const A, B, C, Weights: TPointF): TPointF;
begin
  Result := PointF(A.X + (B.X - A.X) * Weights.X + (C.X - A.X) * Weights.Y,
    A.Y + (B.Y - A.Y) * Weights.X + (C.Y - A.Y) * Weights.Y);
end;

function Cross(const A, B, C: TPointF): Double;
begin
  Result := (B.X - A.X) * (C.Y - A.Y) - (B.Y - A.Y) * (C.X - A.X);
end;

procedure InsertCell(Cells: TList<TCell>; const P: TPointPath; I, J, K: Integer);
var
  B, C: TPointF;
  D, BB, CC: Double;
  Cell: TCell;
begin
  D := Cross(P[I], P[J], P[K]);
  if Abs(D) < 1E-9 then Exit;
  if D < 0 then
  begin
    Cell.Triangle.B := K;
    Cell.Triangle.C := J;
  end
  else
  begin
    Cell.Triangle.B := J;
    Cell.Triangle.C := K;
  end;
  Cell.Triangle.A := I;
  B := P[J] - P[I];
  C := P[K] - P[I];
  BB := Sqr(B.X) + Sqr(B.Y);
  CC := Sqr(C.X) + Sqr(C.Y);
  Cell.U := (BB * C.Y - CC * B.Y) / (2 * D);
  Cell.V := (B.X * CC - C.X * BB) / (2 * D);
  Cell.RadiusSquared := Sqr(Cell.U) + Sqr(Cell.V);
  Cell.U := Cell.U + P[I].X;
  Cell.V := Cell.V + P[I].Y;
  Cells.Add(Cell);
end;

procedure AddBoundary(Edges: TList<TEdge>; A, B: Integer);
var
  I: Integer;
  Edge: TEdge;
begin
  for I := 0 to Edges.Count - 1 do
    if (Edges[I].A = B) and (Edges[I].B = A) then
    begin
      Edges.Delete(I);
      Exit;
    end;
  Edge.A := A;
  Edge.B := B;
  Edges.Add(Edge);
end;

function Triangulate(const Points: TPointPath): TTriangles;
var
  P: TPointPath;
  Cells: TList<TCell>;
  Edges: TList<TEdge>;
  Edge: TEdge;
  Cell: TCell;
  T: TTriangle;
  I, J, Count, Size: Integer;
  Duplicate: Boolean;
begin
  Result := nil;
  Count := Length(Points);
  if Count < 3 then Exit;
  P := Points + [PointF(-128, -128), PointF(256, -128), PointF(-128, 256)];
  Cells := TList<TCell>.Create;
  Edges := TList<TEdge>.Create;
  try
    InsertCell(Cells, P, Count, Count + 1, Count + 2);
    for I := 0 to Count - 1 do
    begin
      Duplicate := False;
      for J := 0 to I - 1 do
        if (Sqr(P[I].X - P[J].X) + Sqr(P[I].Y - P[J].Y)) < 1E-10 then
        begin
          Duplicate := True;
          Break;
        end;
      if Duplicate then Continue;
      Edges.Clear;
      for J := Cells.Count - 1 downto 0 do
      begin
        Cell := Cells[J];
        if Sqr(P[I].X - Cell.U) + Sqr(P[I].Y - Cell.V) > Cell.RadiusSquared + 1E-9 then Continue;
        T := Cell.Triangle;
        AddBoundary(Edges, T.A, T.B);
        AddBoundary(Edges, T.B, T.C);
        AddBoundary(Edges, T.C, T.A);
        Cells.Delete(J);
      end;
      for Edge in Edges do
        InsertCell(Cells, P, Edge.A, Edge.B, I);
    end;
    SetLength(Result, Cells.Count);
    Size := 0;
    for Cell in Cells do
    begin
      T := Cell.Triangle;
      if (T.A >= Count) or (T.B >= Count) or (T.C >= Count) then Continue;
      Result[Size] := T;
      Inc(Size);
    end;
    SetLength(Result, Size);
  finally
    Edges.Free;
    Cells.Free;
  end;
end;

function ContainsPoint(const Polygon: TPointPath; const P: TPointF): Boolean;
var
  A, B: TPointF;
  I: Integer;
begin
  Result := False;
  if Length(Polygon) < 3 then Exit;
  A := Polygon[High(Polygon)];
  for I := 0 to High(Polygon) do
  begin
    B := Polygon[I];
    if ((A.Y > P.Y) <> (B.Y > P.Y)) and
      (P.X < (B.X - A.X) * (P.Y - A.Y) / (B.Y - A.Y) + A.X) then
      Result := not Result;
    A := B;
  end;
end;

function OutlineDistance(const Polygon: TPointPath; const P: TPointF): Single;
var
  A, B, D, Delta: TPointF;
  LengthSquared, T, Nearest: Double;
begin
  if Length(Polygon) < 3 then Exit(-1);
  Nearest := 2;
  A := Polygon[High(Polygon)];
  for B in Polygon do
  begin
    D := B - A;
    Delta := P - A;
    LengthSquared := Sqr(D.X) + Sqr(D.Y);
    if LengthSquared > 1E-12 then
    begin
      T := EnsureRange((D.X * Delta.X + D.Y * Delta.Y) / LengthSquared, 0, 1);
      Delta := Delta - PointF(D.X * T, D.Y * T);
    end;
    Nearest := Min(Nearest, Sqr(Delta.X) + Sqr(Delta.Y));
    A := B;
  end;
  Result := Sqrt(Nearest);
  if not ContainsPoint(Polygon, P) then Result := -Result;
end;

end.
