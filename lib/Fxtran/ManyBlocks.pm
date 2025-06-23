package Fxtran::ManyBlocks;

use Data::Dumper;

use strict;

use Fxtran::Common;
use Fxtran::Loop;
use Fxtran::Stack;
use Fxtran::Call;
use Fxtran::Subroutine;
use Fxtran::Pragma;
use Fxtran::Finder;
use Fxtran::Style;
use Fxtran::Decl;
use Fxtran::Inline;
use Fxtran;

sub processSingleSection
{
  my ($pu, $par, $var2dim, $typearg, $KGPBLKS, %opts) = @_;

  my ($style, $pragma) = @opts{qw (style pragma)};

  my @nproma = $style->nproma ();
  my $jlon = $style->jlon ();
  my $kidia = $style->kidia ();
  my $kfdia = $style->kfdia ();
  
  # Make the section single column
  
  &Fxtran::Loop::removeNpromaLoopsInSection
  (
    $par, 
    style => $style, 
    var2dim => $var2dim,
  );
  
  # Get JLON indexed expressions and add JBLK as last index
  
  for my $sslt (&F ('.//array-R/section-subscript-LT[./section-subscript[string(.)="?"]]', $jlon, $par))
    {
      $sslt->appendChild ($_) for (&t (", "), &n ('<section-subscript><lower-bound>' . &e ('JBLK') . '</lower-bound></section-subscript>'));
    }
  
  
  # JBLK slice for array arguments
  
  for my $expr (&F ('.//call-stmt/arg-spec/arg/named-E', $par))
    {
      my ($N) = &F ('./N', $expr, 1);
      next unless (my $nd = $var2dim->{$N});
  
      my ($rlt) = &F ('./R-LT', $expr);
  
      unless ($rlt)
        {
          $rlt = &n ('<R-LT><array-R>(<section-subscript-LT>' . join (', ', ('<section-subscript>:</section-subscript>') x $nd) . '</section-subscript-LT>)</array-R></R-LT>');
          $expr->appendChild ($rlt);
        }
  
      my ($sslt) = &F ('./array-R/section-subscript-LT', $rlt);
      $sslt->appendChild ($_) for (&t (', '), &n ('<section-subscript><lower-bound>' . &e ('JBLK') . '</lower-bound></section-subscript>'));
  
      if ($opts{'array-slice-to-address'})  # Transform array slice to the address of the first element of the slice
                                            # We assume that the slice is a contiguous chunk of memory
        {
          my @ss = &F ('./array-R/section-subscript-LT/section-subscript', $rlt); 
  
          for my $i (0 .. $#ss-1)
            {
              my $ss = $ss[$i];
  
              my ($lb) = &F ('./lower-bound', $ss);
              my ($ub) = &F ('./upper-bound', $ss);
              my ($dd) = &F ('./text()[string(.)=":"]', $ss);
  
              $_->unbindNode () 
                for ($ss->childNodes ());
  
              if ($lb)
                {
                  $ss->appendChild ($lb);
                }
              else
                {
                  $ss->appendChild (&n ('<lower-bound>' . &e ("LBOUND ($N, " . ($i+1) . ")") . '</lower-bound>'));
                }
            }
        }
    }
  
  # Move section contents into a DO loop over KLON
  
  my ($do_jlon) = &fxtran::parse (fragment => << "EOF");
DO $jlon = $kidia, MERGE ($nproma[0], $kfdia, JBLK < $KGPBLKS)
ENDDO
EOF
  
  for my $x ($par->childNodes ())
    {
      $do_jlon->insertBefore ($x, $do_jlon->lastChild);
    }
  
  $par->replaceNode ($do_jlon);    
  
  # Use a stack
  
  if (&Fxtran::Stack::addStackInSection ($do_jlon))
    {
      &Fxtran::Stack::iniStackManyBlocks 
        ( 
          $do_jlon, stack84 => 1, JBLKMIN => 1, KGPBLKS => $KGPBLKS, 
          $opts{'use-stack'} ? ('stack-macro' => 'stackd', 'stack-base' => 'YLSTACKBASE') : (),
        );
    }
  
  # Replace KIDIA/KFDIA by JLON in call statements
  
  for my $call (&F ('.//call-stmt', $do_jlon))
    {
      for my $var ($kidia, $kfdia)
        {
          for my $expr (&F ('.//named-E[string(.)="?"]', $var, $call))
            {
              $expr->replaceNode (&e ($jlon));
            }
        }
    }
  
  # Add single column suffix to routines called in this section
  
  &Fxtran::Call::addSuffix 
  (
    $pu,
    section => $do_jlon,
    suffix => $opts{'suffix-singlecolumn'},
    'merge-interfaces' => $opts{'merge-interfaces'},
  );
  
  # Move loop over NPROMA into a loop over the blocks
  
  my ($do_jblk) = &fxtran::parse (fragment => << "EOF");
DO JBLK = 1, $KGPBLKS
ENDDO
EOF

  my $do_jlon1 = $do_jlon->cloneNode (); $do_jlon1->appendChild ($_) for ($do_jlon->childNodes ());
  
  $do_jblk->insertBefore ($_, $do_jblk->lastChild) 
    for ($do_jlon1, &t ("\n"));
  
  $do_jlon->replaceNode ($do_jblk); $do_jlon = $do_jlon1;
  
  # Find private variables, derived typed arguments, NPROMA blocked arrays
  
  my (%priv, %nproma, %type);
  
  for my $expr (&F ('.//named-E', $do_jlon))
    {
      my ($n) = &F ('./N', $expr, 1);
      if ($var2dim->{$n})
        {
          $nproma{$n}++;
        }
      elsif ($typearg->{$n})
        {
          $type{$n}++;
        }
      else
        {
          my $p = $expr->parentNode;
          $priv{$n}++ if (($p->nodeName eq 'E-1') || ($p->nodeName eq 'do-V'));
        }
    }
  
  # Add OpenACC directive  
  
  $pragma->insertLoopVector ($do_jlon, PRIVATE => [sort (keys (%priv))]);
  
  $pragma->insertParallelLoopGang 
    ( 
      $do_jblk, PRIVATE => ['JBLK'], VECTOR_LENGTH => [$nproma[0]], IF => ['LDACC'],
      $opts{'use-stack'}
     ? (PRESENT => [sort (keys (%nproma), keys (%type))])
     : ()
    );

}

sub processSingleRoutine
{
  my ($pu, %opts) = @_;

  my $find = $opts{find};

  my $KGPBLKS = 'KGPBLKS';

  for my $in (@{ $opts{inlined} })
    {
      my $f90in = $find->resolve (file => $in);
      my $di = &Fxtran::parse (location => $f90in, fopts => [qw (-construct-tag -line-length 512 -canonic -no-include)], dir => $opts{tmp});
      &Fxtran::Canonic::makeCanonic ($di, %opts);
      &Fxtran::Inline::inlineExternalSubroutine ($pu, $di, %opts);
    }
      
  my $style = $opts{style};
  my $pragma = $opts{pragma};

  my ($dp) = &F ('./specification-part/declaration-part', $pu);
  my ($ep) = &F ('./execution-part', $pu);
  
  my @nproma = $style->nproma ();
  my $jlon = $style->jlon ();
  my $kidia = $style->kidia ();
  my $kfdia = $style->kfdia ();
  
  $opts{'use-stack'} = 1;

  # Arrays dimensioned with KLON and their dimensions

  my $var2dim = &Fxtran::Loop::getVarToDim ($pu, style => $style);
  my $typearg = {};
  
  {
    # Derived types, assume they are present on the device
    my @typearg = &F ('./T-decl-stmt[./_T-spec_/derived-T-spec]/EN-decl-LT/EN-decl/EN-N', $dp, 1);

    my @arg = &F ('./subroutine-stmt/dummy-arg-LT/arg-N', $pu, 1);
    my %arg = map { ($_, 1) } @arg;

    $typearg = {map { ($_, 1) } grep { $arg{$_} } @typearg};

    unless ($opts{'use-stack'})
      {
        my @present = grep { $var2dim->{$_} || $typearg->{$_} } @arg;
        my @create = grep { ! $arg{$_} } sort (keys (%$var2dim));
       
        # Create local arrays, assume argument arrays are on the device
        $pragma->insertData ($ep, PRESENT => \@present, CREATE => \@create, IF => ['LDACC']);
      }

  }
  
  # Parallel sections

  my @par = &F ('.//parallel-section', $pu);
  
  for my $par (@par)
    {
      &processSingleSection ($pu, $par, $var2dim, $typearg, $KGPBLKS, %opts);
    }
  
  # Add single block suffix to routines not called from within parallel sections

  &Fxtran::Call::addSuffix 
  (
    $pu,
    suffix => $opts{'suffix-manyblocks'},
    'merge-interfaces' => $opts{'merge-interfaces'},
    match => sub { my $proc = shift; ! ($proc =~ m/$opts{'suffix-singlecolumn'}$/i) },
  );

  # Add KGPLKS argument to manyblock routines + add LDACC argument
  
  for my $call (&F ('.//call-stmt[contains(string(procedure-designator),"?")]', $opts{'suffix-manyblocks'}, $ep))
    {
      my ($argspec) = &F ('./arg-spec', $call);
      for my $nproma (@nproma)
        {
          next unless (my ($arg) = &F ('./arg[string(.)="?"]', $nproma, $argspec));
          $arg->parentNode->insertAfter ($_, $arg) for (&n ('<arg>' . &e ($KGPBLKS) . '</arg>'), &t (", "));
          last;
        }
      $argspec->appendChild ($_) for (&t (", "), &n ("<arg><arg-N><k>LDACC</k></arg-N> = " . &e ('LDACC') . '</arg>'));

      if ($opts{'use-stack'})
        {
          $argspec->appendChild ($_) for (&t (", "), &n ("<arg><arg-N><k>YDSTACKBASE</k></arg-N> = " . &e ('YLSTACKBASE') . '</arg>'));
        }
    }
  
  # Add KGPBLKS dummy argument

  for my $nproma (@nproma)
    {
      next unless (my ($arg) = &F ('./subroutine-stmt/dummy-arg-LT/arg-N[string(.)="?"]', $nproma, $pu));
      $arg->parentNode->insertAfter ($_, $arg) for (&n ("<arg-N><N><n>$KGPBLKS</n></N></arg-N>"), &t (", "));      

      my ($decl_nproma) = &F ('./T-decl-stmt[./EN-decl-LT/EN-decl[string(EN-N)="?"]]', $nproma, $dp);

      my $decl_kgpblks = $decl_nproma->cloneNode (1);

      my ($n) = &F ('./EN-decl-LT/EN-decl/EN-N/N/n/text()', $decl_kgpblks);

      $n->setData ($KGPBLKS);

      $dp->insertAfter ($_, $decl_nproma) for ($decl_kgpblks, &t ("\n"));

      last;
    }

  # Add LDACC argument
  
  {
    my ($dal) = &F ('./subroutine-stmt/dummy-arg-LT', $pu);
    my @arg = &F ('./arg-N', $dal, 1);

    my ($decl) = &F ('./T-decl-stmt[./EN-decl-LT/EN-decl[string(EN-N)="?"]]', $arg[-1], $dp);

    $dp->insertAfter ($_, $decl) for (&s ("LOGICAL, INTENT (IN) :: LDACC"), &t ("\n"));
    $dal->appendChild ($_) for (&t (", "), &n ("<arg-N>LDACC</arg-N>"));

    if ($opts{'use-stack'})
      {
        $dp->insertAfter ($_, $decl) for (&s ("TYPE (STACK), INTENT (IN) :: YDSTACKBASE"), &t ("\n"));
        $dal->appendChild ($_) for (&t (", "), &n ("<arg-N>YDSTACKBASE</arg-N>"));
      }
  }

  # Stack definition & declaration
  
  my ($implicit) = &F ('.//implicit-none-stmt', $pu);
  
  $implicit->parentNode->insertBefore (&n ('<include>#include "<filename>stack.h</filename>"</include>'), $implicit);
  $implicit->parentNode->insertBefore (&t ("\n"), $implicit);
 

  &Fxtran::Decl::declare ($pu, 'TYPE (STACK) :: YLSTACK');
  &Fxtran::Decl::declare ($pu, 'TYPE (STACK) :: YLSTACKBASE') if ($opts{'use-stack'});
  &Fxtran::Decl::use ($pu, 'USE STACK_MOD');

  # Add extra dimensions to all nproma arrays + make all array spec implicit


  for my $stmt (&F ('./T-decl-stmt', $dp))
    {
      next unless (my ($as) = &F ('./EN-decl-LT/EN-decl/array-spec', $stmt));

      my ($sslt) = &F ('./shape-spec-LT', $as);

      my @ss = &F ('./shape-spec', $sslt);

      for my $nproma (@nproma)
        {
          goto NPROMA if ($ss[0]->textContent eq $nproma);
        }

      next;

NPROMA:

     if (&F ('./attribute[string(attribute-N)="INTENT"]', $stmt))
       {
         # Dummy argument : use implicit shape

         my $comment = $as->textContent;

         my $iss = &n ('<shape-spec>:</shape-spec>');

         for my $ss (@ss)
           {
             next unless (my ($ub) = &F ('./upper-bound', $ss));  # Only for dimensions with upper-bound : (N1:N2) or (N)
             if (my ($lb) = &F ('./lower-bound', $ss))
               {
                 $ub->unbindNode ();                              # (N1:N2) -> (N1:)
               }
             else
               {
                 $ub->replaceNode ($iss->cloneNode (1));          # (N) -> (:)
               }
           }

         $sslt->appendChild ($_) for (&t (", "), $iss);

         $dp->insertAfter ($_, $stmt) for (&n ("<C>! $comment</C>"), &t (' '));
       }   
     else
       {
         # Local variable : add KGPBLKS dimension
         $sslt->appendChild ($_) for (&t (", "), &n ('<shape-spec>' . &e ($KGPBLKS) . '</shape-spec>'));
       }
    

    }

  &Fxtran::Decl::declare ($pu, 'INTEGER :: JBLK');

  &Fxtran::Subroutine::addSuffix ($pu, $opts{'suffix-manyblocks'});

  &stackAllocateTemporaries ($pu, $var2dim, %opts)
    if ($opts{'use-stack'});
}

sub stackAllocateTemporaries
{
  my ($pu, $var2dim, %opts) = @_;

  my ($ep) = &F ('./execution-part', $pu);
  my ($dp) = &F ('./specification-part/declaration-part', $pu);

  $ep->insertBefore (my $C = &n ("<C>!</C>"), $ep->firstChild);

  for my $decl (&F ('./T-decl-stmt', $dp))
    {
      next if (&F ('./attribute[string(./attribute-N)="INTENT"]', $decl));
      my ($en_decl) = &F ('./EN-decl-LT/EN-decl', $decl);
      my ($n) = &F ('./EN-N', $en_decl, 1);
      next unless ($var2dim->{$n});
      my ($ts) = &F ('./_T-spec_', $decl, 1);
      my ($as) = &F ('./array-spec', $en_decl, 1);
      $decl->replaceNode (&t ("temp ($ts, $n, $as)"));

      my ($if) = &fxtran::parse (fragment => << "EOF");
IF (KIND ($n) == 8) THEN
  alloc8 ($n)
ELSEIF (KIND ($n) == 4) THEN
  alloc4 ($n)
ELSE
  STOP 1
ENDIF
EOF

      $ep->insertBefore ($_, $ep->firstChild) for (&t ("\n"), $if);
    }

  # Before allocations : initialize YLSTACK
  for my $x (&t ("\n"), &s ("YLSTACK = YDSTACKBASE"), &t ("\n"))
    {
      $ep->insertBefore ($x, $ep->firstChild);
    }

  # After allocations : initialize YLSTACKBASE
  for my $x (&t ("\n"), &t ("\n"), &s ("YLSTACKBASE = YLSTACK"))
    {
      $ep->insertAfter ($x, $C);
    }

  $C->unbindNode ();



}

1;
