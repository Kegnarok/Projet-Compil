with Ada.Text_IO; use Ada.Text_IO;

procedure Main is
   Integer : Char := 'c';
     
   procedure Aux(X : Integer) is
   begin
      Put(X);
   end;
     
begin
   Aux(Integer);
end;
