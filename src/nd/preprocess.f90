module spral_nd_preprocess
   use spral_nd_types
   implicit none

   private
   public :: compress_by_svar,            & ! detect and use supervariables
             construct_full_from_full,    & ! lwr+upr CSC -> lwr+upr internal
             construct_full_from_lower,   & ! lwr CSC -> lwr+upr internal
             remove_dense_rows              ! drop dense rows, upd perm

contains

   !
   ! Detects supervariables and compresses graph in place
   !
   subroutine compress_by_svar(a_n, a_ne, a_ptr, a_row, a_weight, a_n_curr, &
         a_ne_curr, nsvar, svar, sinvp, num_zero_row, options, st)
      integer, intent(in) :: a_n
      integer, intent(in) :: a_ne
      integer, dimension(a_n), intent(inout) :: a_ptr
      integer, dimension(a_ne), intent(inout) :: a_row
      integer, dimension(a_n), intent(out) :: a_weight
      integer, intent(out) :: a_n_curr
      integer, intent(out) :: a_ne_curr
      integer, intent(out) :: nsvar
      integer, dimension(a_n), intent(out) :: svar
      integer, dimension(a_n), intent(out) :: sinvp
      integer, intent(out) :: num_zero_row
      type(nd_options) :: options
      integer, intent(out) :: st

      integer :: i, j, k
      integer :: nnz_rows ! number of non-zero rows
      integer, allocatable, dimension(:) :: ptr2, row2, perm

      allocate (ptr2(a_n+1), row2(a_ne), perm(a_n), stat=st)
      if (st.ne.0) return

      ! Construct simple identity permutation
      perm(:) = (/ (i,i=1,a_n) /)
      sinvp(:) = (/ (i,i=1,a_n) /)

      ! Identify supervariables
      nnz_rows = a_n
      call nd_supervars(nnz_rows, a_ne, a_ptr, a_row, perm, sinvp, nsvar, &
         svar, st)
      if (st.ne.0) return

      num_zero_row = a_n - nnz_rows
      if (options%print_level.ge.2 .and. options%unit_diagnostics.gt.0) &
         write (options%unit_diagnostics,'(a,i10)') &
            'Number supervariables: ', nsvar + num_zero_row

      ! If there are no supervariables, don't bother compressing: return
      if (nsvar+num_zero_row==a_n) then
         a_n_curr = a_n
         a_ne_curr = a_ne
         a_weight(:) = 1
         return
      end if

      ! Otherwise, compress the matrix
      call nd_compress_by_svar(a_n, a_ne, a_ptr, a_row, sinvp, nsvar, &
         svar, ptr2, row2, st)
      if (st.ne.0) return

      ! FIXME: what is happening below? can it be simplified?
      a_n_curr = nsvar

      ! Fill a_ptr removing any diagonal entries
      a_ptr(:) = 0

      ! Set a_ptr(j) to hold no. nonzeros in column j
      do j = 1, a_n_curr
         do k = ptr2(j), ptr2(j+1) - 1
            i = row2(k)
            if (j<i) then
               a_ptr(i) = a_ptr(i) + 1
               a_ptr(j) = a_ptr(j) + 1
            end if
         end do
      end do

      ! Set a_ptr(j) to point to where row indices will end in a_row
      do j = 2, a_n_curr
         a_ptr(j) = a_ptr(j-1) + a_ptr(j)
      end do
      a_ne_curr = a_ptr(a_n_curr)
      ! Initialise all of a_row to 0
      a_row(1:a_ne_curr) = 0

      ! Fill a_row and a_ptr
      do j = 1, a_n_curr
         do k = ptr2(j), ptr2(j+1) - 1
            i = row2(k)
            if (j<i) then
               a_row(a_ptr(i)) = j
               a_row(a_ptr(j)) = i
               a_ptr(i) = a_ptr(i) - 1
               a_ptr(j) = a_ptr(j) - 1
            end if
         end do
      end do

      ! Reset a_ptr to point to where column starts
      do j = 1, a_n_curr
         a_ptr(j) = a_ptr(j) + 1
      end do

      ! Initialise a_weight
      a_weight(1:a_n_curr) = svar(1:a_n_curr)
      a_weight(a_n_curr+1:a_n_curr+num_zero_row) = 1

      ! Add zero rows/cols to matrix
      a_ptr(a_n_curr+1:a_n_curr+num_zero_row) = a_ne_curr + 1
      a_n_curr = a_n_curr + num_zero_row

      ! set svar(:) such that svar(i) points to the end of the list of variables
      ! in sinvp for supervariable i
      do i = 2, nsvar
         svar(i) = svar(i) + svar(i-1)
      end do
      j = svar(nsvar)
      do i = 1, num_zero_row
         svar(nsvar+i) = j + 1
         j = j + 1
      end do
   end subroutine compress_by_svar
   ! ---------------------------------------------------
   ! remove_dense_rows
   ! ---------------------------------------------------
   ! Identifies and removes dense rows
   subroutine remove_dense_rows(a_n_in, a_ne_in, a_ptr, a_row, iperm, work, &
       options,info)
     integer, intent(inout) :: a_n_in ! dimension of subproblem before dense
     ! rows removed
     integer, intent(inout) :: a_ne_in ! no. nonzeros of subproblem before
     ! dense rows removed
     integer, intent(inout) :: a_ptr(a_n_in) ! On input a_ptr(i) contains
     ! position in a_row that entries for column i start. This is then
     ! used to hold positions for submatrices after dense row removed
     integer, intent(inout) :: a_row(a_ne_in) ! On input a_row contains
     ! row
     ! indices of the non-zero rows. Diagonal entries have been removed
     ! and the matrix expanded.This is then used to hold row indices for
     ! submatrices after partitioning
     integer, intent(inout) :: iperm(a_n_in) ! On input, iperm(i) contains
     ! the row in the original matrix (when nd_nested was called) that
     ! row i in this sub problem maps to. On output, this is updated to
     ! reflect the computed permutation.
     integer, intent(out) :: work(4*a_n_in) ! Used during the algorithm to
     ! reduce need for allocations. The output is garbage.
     type (nd_options), intent(in) :: options
     type (nd_inform), intent(inout) :: info

     ! ---------------------------------------------
     integer :: unit_diagnostics ! unit on which to print diagnostics
     integer :: deg, prev, next, dense ! pointers into work array
     integer :: ndense ! number of dense rows found
     integer :: max_deg ! maximum degree
     integer :: degree, i, j, k, l, l1, l2, m, m1
     logical :: printi, printd
     integer :: a_n_out ! dimension of subproblem after dense rows removed
     integer :: a_ne_out ! no. nonzeros of subproblem after dense rows removed

     ! ---------------------------------------------
     ! Printing levels
     unit_diagnostics = options%unit_diagnostics
     printi = (options%print_level==1 .and. unit_diagnostics>=0)
     printd = (options%print_level>=2 .and. unit_diagnostics>=0)
     ! ---------------------------------------------------
     if (printi .or. printd) then
       write (unit_diagnostics,'(a)') ' '
       write (unit_diagnostics,'(a)') 'Find and remove dense rows'
     end if

     ! Set pointers into work array
     deg = 0
     prev = deg + a_n_in
     next = prev + a_n_in
     dense = next + a_n_in

     ! By the end of this loop work(dense+i) will be
     ! 0 if row is not dense
     ! <0 otherwise. The larger the number, the earlier the row was
     ! was determined to be dense.
     ndense = 0
     max_deg = 0
     work(deg+1:deg+a_n_in) = 0

     ! Calculate degree of each row before anything removed
     do i = 1, a_n_in
       k = a_ptr(i)
       if (i<a_n_in) then
         degree = a_ptr(i+1) - k
       else
         degree = a_ne_in - a_ptr(a_n_in) + 1
       end if
       work(dense+i) = degree
       if (degree/=0) then
         max_deg = max(max_deg,degree)
         call dense_add_to_list(a_n_in,work(next+1:next+a_n_in),&
             work(prev+1:prev+a_n_in),work(deg+1:deg+a_n_in),i,degree)
       end if
     end do
     degree = max_deg
     a_n_out = a_n_in
     a_ne_out = a_ne_in

     do while (real(degree)-real(a_ne_out)/real(a_n_out)>=40*(real(a_n_out- &
         1)/real(a_n_out))*LOG(real(a_n_out)) .and. degree>0)
       ! do while (real(degree) - real(a_ne_out)/real(a_n_out)>= &
       ! 300*(real(a_n_out-1)/real(a_n_out)) &
       ! .and. degree>0)
       i = work(deg+degree)
       ndense = ndense + 1
       work(dense+i) = -ndense
       call dense_remove_from_list(a_n_in,work(next+1:next+a_n_in),&
             work(prev+1:prev+a_n_in),work(deg+1:deg+a_n_in),i,degree)
       ! update degrees of adjacent vertices
       if (i<a_n_in) then
         l = a_ptr(i+1) - 1
       else
         l = a_ne_in
       end if
       do k = a_ptr(i), l
         j = a_row(k)
         if (work(dense+j)>0) then
           call dense_remove_from_list(a_n_in,work(next+1:next+a_n_in),&
             work(prev+1:prev+a_n_in),work(deg+1:deg+a_n_in),j,work(dense+j))
           work(dense+j) = work(dense+j) - 1
           if (work(dense+j)>0) then
             call dense_add_to_list(a_n_in,work(next+1:next+a_n_in),&
             work(prev+1:prev+a_n_in),work(deg+1:deg+a_n_in),j,work(dense+j))
           end if
         end if
       end do
       a_n_out = a_n_out - 1
       a_ne_out = a_ne_out - 2*degree
       if (work(deg+degree)==0) then
         ! Find next largest degree
         degree = degree - 1
         do
           if (degree==0) exit
           if (work(deg+degree)>0) exit
           degree = degree - 1
         end do
       end if
     end do

     ! By the end of this loop work(dense+i) will be
     ! >=0 if row is not dense
     ! <0 otherwise. The larger the number, the earlier the row was
     ! was determined to be dense.
     ! !!!!

     if (ndense>0) then
       if (printi .or. printd) then
         write (unit_diagnostics,'(a)') ' '
         write (unit_diagnostics,'(i10,a)') ndense, ' dense rows detected'
       end if
       info%dense = ndense

       a_n_out = 0
       l = a_n_in + 1
       do i = 1, a_n_in
         k = work(dense+i)
         if (k>=0) then
           a_n_out = a_n_out + 1
           work(dense+i) = a_n_out
           work(next+a_n_out) = i
         else
           work(next+l+k) = i
         end if
       end do

       k = 1
       j = 1

       do i = 1, a_n_in
         l1 = a_ptr(i)
         if (i<a_n_in) then
           l2 = a_ptr(i+1) - 1
         else
           l2 = a_ne_in
         end if
         if (work(dense+i)>=0) then
           a_ptr(j) = k
           do l = l1, l2
             m = a_row(l)
             m1 = work(dense+m)
             if (m1>=0) then
               a_row(k) = m1
               k = k + 1
             end if
           end do
           j = j + 1
         end if
       end do
       a_ptr(j) = k
       if (printd) then
         ! Print out a_ptr and a_row
         write (unit_diagnostics,'(a11)') 'a_n_out = '
         write (unit_diagnostics,'(i15)') a_n_out
         write (unit_diagnostics,'(a11)') 'a_ne_out = '
         write (unit_diagnostics,'(i15)') a_ne_out
         write (unit_diagnostics,'(a8)') 'a_ptr = '
         write (unit_diagnostics,'(5i15)') (a_ptr(i),i=1,a_n_out)
         write (unit_diagnostics,'(a8)') 'a_row = '
         write (unit_diagnostics,'(5i15)') (a_row(i),i=1,a_ne_out)
       else if (printi) then
         ! Print out first few entries of a_ptr and a_row
         write (unit_diagnostics,'(a11)') 'a_n_out = '
         write (unit_diagnostics,'(i15)') a_n_out
         write (unit_diagnostics,'(a11)') 'a_ne_out = '
         write (unit_diagnostics,'(i15)') a_ne_out
         write (unit_diagnostics,'(a21)') 'a_ptr(1:min(5,a_n_out)) = '
         write (unit_diagnostics,'(5i15)') (a_ptr(i),i=1,min(5,a_n_out))
         write (unit_diagnostics,'(a21)') 'a_row(1:min(5,a_ne_out)) = '
         write (unit_diagnostics,'(5i15)') (a_row(i),i=1,min(5,a_ne_out))
       end if
     else

       a_n_out = a_n_in
       a_ne_out = a_ne_in
       work(next+1:next+a_n_in) = (/ (i,i=1,a_n_in) /)
     end if

     do i = 1, a_n_in
       j = work(next+i)
       work(next+i) = iperm(j)
     end do

     do i = 1, a_n_in
       iperm(i) = work(next+i)
     end do

     info%flag = 0
     if (printi .or. printd) then
       call nd_print_message(info%flag,unit_diagnostics, &
         'remove_dense_rows')
     end if

     if (printd) then
       write (unit_diagnostics,'(a,i10)') ' No. dense rows removed: ', &
         a_n_in - a_n_out
     end if
     a_n_in = a_n_out
     a_ne_in = a_ne_out

   end subroutine remove_dense_rows

     subroutine dense_remove_from_list(n,next,prev,deg,irm,ig)
       integer, intent(in) :: n ! order matrix
       integer, intent(inout) :: next(n),prev(n),deg(n)
       integer, intent(in) :: irm, ig
       integer :: inext, ilast

       inext = next(irm)
       ilast = prev(irm)
       if (ilast==0) then
         deg(ig) = inext
         if (inext/=0) prev(inext) = 0
       else
         next(ilast) = inext
         if (inext/=0) prev(inext) = ilast
       end if
     end subroutine dense_remove_from_list

     subroutine dense_add_to_list(n,next,prev,deg,irm,ig)
       integer, intent(in) :: n ! order matrix
       integer, intent(inout) :: next(n),prev(n),deg(n)
       integer, intent(in) :: irm, ig
       integer :: inext

       inext = deg(ig)
       deg(ig) = irm
       next(irm) = inext
       if (inext/=0) prev(inext) = irm
       prev(irm) = 0
     end subroutine dense_add_to_list
   !
   ! Constructs a full matrix (without diagonals) from one with only lower
   ! triangle stored (perhaps with diagonals)
   !
   subroutine construct_full_from_lower(n, ptr, row, n_out, ne_out, ptr_out, &
         row_out, options, st)
      integer, intent(in) :: n
      integer, dimension(n+1), intent(in) :: ptr
      integer, dimension(ptr(n+1)-1), intent(in) :: row
      integer, intent(out) :: n_out
      integer, intent(out) :: ne_out
      integer, dimension(:), allocatable, intent(out) :: ptr_out
      integer, dimension(:), allocatable, intent(out) :: row_out
      type (nd_options), intent(in) :: options
      integer, intent(out) :: st

      integer :: i, j, k

      n_out = n
      if (options%print_level.ge.1 .and. options%unit_diagnostics.gt.0) &
         write (options%unit_diagnostics,'(a,i10)') 'n = ', n_out

      ! Allocate space to store pointers for expanded matrix
      allocate (ptr_out(n),stat=st)
      if (st.ne.0) return

      ! Set ptr_out(j) to hold no. nonzeros in column j, without diagonal
      ptr_out(:) = 0
      do j = 1, n
         do k = ptr(j), ptr(j+1) - 1
            i = row(k)
            if (j.ne.i) then
               ptr_out(i) = ptr_out(i) + 1
               ptr_out(j) = ptr_out(j) + 1
            end if
         end do
      end do

      ! Set ptr_out(j) to point to where row indices will end in row_out
      do j = 2, n
         ptr_out(j) = ptr_out(j-1) + ptr_out(j)
      end do
      ne_out = ptr_out(n)

      if (options%print_level.ge.1 .and. options%unit_diagnostics.gt.0) &
         write (options%unit_diagnostics,'(a,i10)') &
            'entries in expanded matrix with diags removed = ', ne_out

      ! Allocate space to store row indices of expanded matrix
      allocate (row_out(ne_out), stat=st)
      if (st.ne.0) return

      ! Fill row_out and ptr_out
      do j = 1, n
         do k = ptr(j), ptr(j+1) - 1
            i = row(k)
            if (j.ne.i) then
               row_out(ptr_out(i)) = j
               row_out(ptr_out(j)) = i
               ptr_out(i) = ptr_out(i) - 1
               ptr_out(j) = ptr_out(j) - 1
            end if
         end do
      end do

      ! Reset ptr_out to point to where column starts
      do j = 1, n
         ptr_out(j) = ptr_out(j) + 1
      end do
   end subroutine construct_full_from_lower

   !
   ! Constructs a new full matrix (without diagonals) in internal CSC format
   ! from user supplied matrix in standard CSC format (which may have diagonals)
   !
   subroutine construct_full_from_full(n, ptr, row, n_out, ne_out, ptr_out, &
         row_out, options, st)
      integer, intent(in) :: n
      integer, dimension(n+1), intent(in) :: ptr
      integer, dimension(ptr(n+1)-1), intent(in) :: row
      integer, intent(out) :: n_out
      integer, intent(out) :: ne_out
      integer, dimension(:), allocatable, intent(out) :: ptr_out
      integer, dimension(:), allocatable, intent(out) :: row_out
      type (nd_options), intent(in) :: options
      integer, intent(out) :: st

      integer :: i, j, k, p
      integer :: ndiags

      ! Set the dimension of the expanded matrix
      n_out = n
      if (options%print_level.ge.1 .and. options%unit_diagnostics.gt.0) &
         write (options%unit_diagnostics,'(a,i10)') 'n = ', n

      ! Work out how many diagonal entries need removing
      ndiags = 0
      do i = 1, n
         do j = ptr(i), ptr(i+1) - 1
            k = row(j)
            if (k.eq.i) ndiags = ndiags + 1
         end do
      end do
      ne_out = ptr(n+1) - 1 - ndiags

      ! Allocate space to store pointers and rows for expanded matrix
      allocate (ptr_out(n), row_out(ne_out), stat=st)
      if (st.ne.0) return

      if (ndiags.eq.0) then
         ! No diagonal entries so do direct copy
         ptr_out(1:n) = ptr(1:n)
         row_out(1:ne_out) = row(1:ne_out)
      else
         ! Diagonal entries present
         k = 1
         do i = 1, n
            ptr_out(i) = k
            do p = ptr(i), ptr(i+1) - 1
               j = row(p)
               if (i.ne.j) then
                  row_out(k) = j
                  k = k + 1
               end if
            end do
         end do
      end if
   end subroutine construct_full_from_full

   subroutine nd_supervars(n,ne,ptr,row,perm,invp,nsvar,svar,st)
     ! Detects supervariables - modified version of subroutine from hsl_mc78
     integer, intent(inout) :: n ! Dimension of system
     integer, intent(in) :: ne ! Number of entries
     integer, dimension(n), intent(in) :: ptr ! Column pointers
     integer, dimension(ne), intent(in) :: row ! Row indices
     integer, dimension(n), intent(inout) :: perm
     ! perm(i) must hold position of i in the pivot sequence.
     ! On exit, holds the pivot order to be used by factorization.
     integer, dimension(n), intent(inout) :: invp ! inverse of perm
     integer, intent(out) :: nsvar ! number of supervariables
     integer, dimension(n), intent(out) :: svar ! number of vars in each
     ! svar
     integer, intent(out) :: st

     logical :: full_rank ! flags if supervariable 1 has ever become
     ! empty.
     ! If it has not, then the varaibles in s.v. 1 are those that never
     ! occur
     integer :: i
     integer(long) :: ii
     integer :: j
     integer :: idx ! current index
     integer :: next_sv ! head of free sv linked list
     integer :: nsv ! new supervariable to move j to
     integer :: piv ! current pivot
     integer :: col ! current column of A
     integer :: sv ! current supervariable
     integer :: svc ! temporary holding supervariable count
     integer, dimension(:), allocatable :: sv_new ! Maps each
     ! supervariable to
     ! a new supervariable with which it is associated.
     integer, dimension(:), allocatable :: sv_seen ! Flags whether
     ! svariables have
     ! been seen in the current column. sv_seen(j) is set to col when svar
     ! j
     ! has been encountered.
     integer, dimension(:), allocatable :: sv_count ! number of variables
     ! in sv.

     allocate (sv_new(n+1),sv_seen(n+1),sv_count(n+1),stat=st)
     if (st.ne.0) return

     svar(:) = 1
     sv_count(1) = n
     sv_seen(1) = 0

     ! Setup linked list of free super variables
     next_sv = 2
     do i = 2, n
       sv_seen(i) = i + 1
     end do
     sv_seen(n+1) = -1

     ! Determine supervariables using modified Duff and Reid algorithm
     full_rank = .false.
     do col = 1, n
       if (nd_get_ptr(col+1,n,ne,ptr)/=ptr(col)) then
         ! If column is not empty, add implicit diagonal entry
         j = col
         sv = svar(j)
         if (sv_count(sv)==1) then ! Are we only (remaining) var in sv
           full_rank = full_rank .or. (sv==1)
           ! MUST BE the first time that sv has been seen for this
           ! column, so just leave j in sv, and go to next variable.
           ! (Also there can be no other vars in this block pivot)
         else
           ! There is at least one other variable remaining in sv
           ! MUST BE first occurence of sv in the current row/column,
           ! so define a new supervariable and associate it with sv.
           sv_seen(sv) = col
           sv_new(sv) = next_sv
           nsv = next_sv
           next_sv = sv_seen(next_sv)
           sv_new(nsv) = nsv ! avoids problems with duplicates
           sv_seen(nsv) = col
           ! Now move j from sv to nsv
           nsv = sv_new(sv)
           svar(j) = nsv
           sv_count(sv) = sv_count(sv) - 1
           sv_count(nsv) = 1
           ! This sv cannot be empty as initial sv_count was > 1
         end if
       end if
       do ii = ptr(col), nd_get_ptr(col+1, n, ne, ptr) - 1
         j = row(ii)
         sv = svar(j)
         if (sv_count(sv)==1) then ! Are we only (remaining) var in sv
           full_rank = full_rank .or. (sv==1)
           ! If so, and this is first time that sv has been seen for this
           ! column, then we can just leave j in sv, and go to next
           ! variable.
           if (sv_seen(sv)<col) cycle
           ! Otherwise, we have already defined a new supervariable
           ! associated
           ! with sv. Move j to this variable, then retire (now empty) sv.
           nsv = sv_new(sv)
           if (sv==nsv) cycle
           svar(j) = nsv
           sv_count(nsv) = sv_count(nsv) + 1
           ! Old sv is now empty, add it to top of free stack
           sv_seen(sv) = next_sv
           next_sv = sv
         else
           ! There is at least one other variable remaining in sv
           if (sv_seen(sv)<col) then
             ! this is the first occurence of sv in the current row/column,
             ! so define a new supervariable and associate it with sv.
             sv_seen(sv) = col
             sv_new(sv) = next_sv
             sv_new(next_sv) = next_sv ! avoids problems with duplicates
             next_sv = sv_seen(next_sv)
             sv_count(sv_new(sv)) = 0
             sv_seen(sv_new(sv)) = col
           end if
           ! Now move j from sv to nsv
           nsv = sv_new(sv)
           svar(j) = nsv
           sv_count(sv) = sv_count(sv) - 1
           sv_count(nsv) = sv_count(nsv) + 1
           ! This sv cannot be empty as sv_count was > 1
         end if
       end do
     end do


     ! Now modify pivot order such that all variables in each supervariable
     ! are
     ! consecutive. Do so by iterating over pivots in elimination order. If
     ! a
     ! pivot has not already been listed, then order that pivot followed by
     ! any other pivots in that supervariable.

     ! We will build a new inverse permutation in invp, and then find perm
     ! afterwards. First copy invp to perm:
     perm(:) = invp(:)
     ! Next we iterate over the pivots that have not been ordered already
     ! Note: as we begin, all entries of sv_seen are less than or equal to
     ! n+1
     ! hence we can use <=n+1 or >n+1 as a flag to indicate if a variable
     ! has been
     ! ordered.
     idx = 1
     nsvar = 0
     do piv = 1, n
       if (sv_seen(piv)>n+1) cycle ! already ordered
       ! Record information for supervariable
       sv = svar(perm(piv))
       if ( .not. full_rank .and. sv==1) cycle ! Don't touch unused vars
       nsvar = nsvar + 1
       svc = sv_count(sv)
       sv_new(nsvar) = svc ! store # vars in s.v. to copy to svar
       ! later
       j = piv
       ! Find all variables that are members of sv and order them.
       do while (svc>0)
         do j = j, n
           if (svar(perm(j))==sv) exit
         end do
         sv_seen(j) = n + 2 ! flag as ordered
         invp(idx) = perm(j)
         idx = idx + 1
         svc = svc - 1
         j = j + 1
       end do
     end do
     ! Push unused variables to end - these are those vars still in s.v. 1
     if ( .not. full_rank) then
       svc = sv_count(1)
       ! Find all variables that are members of sv and order them.
       j = 1
       do while (svc>0)
         do j = j, n
           if (svar(perm(j))==1) exit
         end do
         invp(idx) = perm(j)
         idx = idx + 1
         svc = svc - 1
         j = j + 1
       end do
       n = n - sv_count(1)
     end if

     ! Recover perm as inverse of invp
     do piv = 1, n
       perm(invp(piv)) = piv
     end do
     ! sv_new has been used to store number of variables in each svar, copy
     ! into
     ! svar where it is returned.
     svar(1:nsvar) = sv_new(1:nsvar)
   end subroutine nd_supervars

   !
   ! Returns ptr(idx) if idx.le.n, or ne+1 otherwise
   !
   integer function nd_get_ptr(idx, n, ne, ptr)
      integer, intent(in) :: idx, n, ne
      integer, dimension(n), intent(in) :: ptr

      if(idx.le.n) then
         nd_get_ptr = ptr(idx)
      else
         nd_get_ptr = ne+1
      endif
   end function nd_get_ptr


   ! This subroutine takes a set of supervariables and compresses the
   ! supplied
   ! matrix using them.

   subroutine nd_compress_by_svar(n,ne,ptr,row,invp,nsvar,svar,ptr2, &
       row2,st)
     integer, intent(in) :: n ! Dimension of system
     integer, intent(in) :: ne ! Number off-diagonal zeros in system
     integer, dimension(n), intent(in) :: ptr ! Column pointers
     integer, dimension(ne), intent(in) :: row ! Row indices
     integer, dimension(n), intent(in) :: invp ! inverse of perm
     integer, intent(in) :: nsvar
     integer, dimension(nsvar), intent(in) :: svar ! super variables of A
     integer, dimension(nsvar+1), intent(out) :: ptr2
     integer, dimension(ne), intent(out) :: row2
     integer, intent(out) :: st

     integer :: piv, svc, sv, col
     integer :: j, idx
     integer, dimension(:), allocatable :: flag, sv_map

     allocate (flag(nsvar),sv_map(n),stat=st)
     if (st.ne.0) return
     flag(:) = 0

     ! Setup sv_map
     piv = 1
     do svc = 1, nsvar
       do piv = piv, piv + svar(svc) - 1
         sv_map(invp(piv)) = svc
       end do
     end do

     piv = 1
     idx = 1
     do svc = 1, nsvar
       col = invp(piv)
       ptr2(svc) = idx
       do j = ptr(col), nd_get_ptr(col+1, n, ne, ptr) - 1
         sv = sv_map(row(j))
         if (flag(sv)==piv) cycle ! Already dealt with this supervariable
         ! Add row entry for this sv
         row2(idx) = sv
         flag(sv) = piv
         idx = idx + 1
       end do
       piv = piv + svar(svc)
     end do
     ptr2(svc) = idx
   end subroutine nd_compress_by_svar

end module spral_nd_preprocess