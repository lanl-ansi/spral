program run_prob
   use spral_core_analyse
   use spral_matrix_util
   use spral_metis_wrapper
   use spral_nd
   use spral_random
   use spral_rutherford_boeing
   implicit none

   integer, parameter :: wp = kind(0d0)
   integer, parameter :: long = selected_int_kind(18)

   ! RB Reader
   type(rb_reader_options) :: rb_options
   integer :: rb_flag
   integer :: flag, more, st

   ! Matrix
   integer :: m, n
   integer, dimension(:), allocatable :: ptr, row, col
   real(wp), dimension(:), allocatable :: val

   ! ND and stats
   type(nd_options) :: options
   type(nd_inform) :: inform
   integer, dimension(:), allocatable :: perm, invp
   integer(long) :: nfact, nflops

   ! Timing
   integer :: start_t, stop_t, rate_t

   ! Controls
   integer :: random
   logical :: with_metis, with_nd

   call proc_args(options, with_metis, with_nd, random)

   ! Read in a matrix
   write(*, "(a)", advance="no") "Reading..."
   rb_options%values = 2 ! make up values if necessary
   call rb_read("matrix.rb", m, n, ptr, row, col, val, rb_options, rb_flag)
   if(rb_flag.ne.0) then
      print *, "Rutherford-Boeing read failed with error ", rb_flag
      stop
   endif
   write(*, "(a)") "ok"

   ! Just to be safe...
   call cscl_verify(6, SPRAL_MATRIX_REAL_SYM_INDEF, n, n, &
      ptr, row, flag, more)
   if(flag.ne.0) then
      print *, "CSCL_VERIFY failed: ", flag, more
      stop
   endif

   ! Randomize order
   if(random.ne.-1) &
      call randomize_matrix(n, ptr, row, random)

   ! Order using spral_nd
   allocate(perm(n), invp(n))
   if(with_nd) then
      write(*, "(a)", advance="no") "Ordering with ND..."
      call system_clock(start_t, rate_t)
      call nd_order(0, n, ptr, row, perm, options, inform)
      call system_clock(stop_t)
      if (inform%flag < 0) then
         print *, "oops on analyse ", inform%flag
         stop
      endif
      write(*, "(a)") "ok"
      print *, "nd_order() took ", (stop_t - start_t)/real(rate_t)
      ! Determine quality
      write(*, "(a)", advance="no") "Determing stats..."
      call calculate_stats(n, ptr, row, perm, nfact, nflops)
      write(*, "(a)") "ok"
      print "(a,es10.2)", "nd nfact = ", real(nfact)
      print "(a,es10.2)", "nd nflop = ", real(nflops)
      print "(a,i10)", "nd ndense = ", inform%dense
      print "(a,i10)", "nd sv var reduce = ", n - inform%dense - inform%nsuper
   endif

   ! Order using metis
   if(with_metis) then
      write(*, "(a)", advance="no") "Ordering with Metis..."
      call system_clock(start_t, rate_t)
      call metis_order(n, ptr, row, perm, invp, flag, st)
      call system_clock(stop_t)
      if (inform%flag < 0) then
         print *, "oops on analyse ", inform%flag
         stop
      endif
      write(*, "(a)") "ok"
      print *, "metis_order() took ", (stop_t - start_t)/real(rate_t)
      ! Determine quality
      write(*, "(a)", advance="no") "Determing stats..."
      call calculate_stats(n, ptr, row, perm, nfact, nflops)
      write(*, "(a)") "ok"
      print "(a,es10.2)", "metis nfact = ", real(nfact)
      print "(a,es10.2)", "metis nflop = ", real(nflops)
   endif

contains

   subroutine proc_args(options, with_metis, with_nd, random)
      type(nd_options), intent(inout) :: options
      logical, intent(out) :: with_metis
      logical, intent(out) :: with_nd
      integer, intent(out) :: random

      integer :: argnum, narg
      character(len=200) :: argval

      ! Defaults
      with_metis = .false.
      with_nd = .true.
      random = -1
      
      ! Process args
      narg = command_argument_count()
      argnum = 1
      do while(argnum <= narg)
         call get_command_argument(argnum, argval)
         argnum = argnum + 1
         select case(argval)
         case("--cost")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%cost_function
            print *, "Set cost function to ", options%cost_function
         case("--refinement")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%refinement
            print *, "Set options%refinement = ", options%refinement
         case("--amd-call")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%amd_call
            print *, "Set options%amd_call = ", options%amd_call
         case("--amd-switch2")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%amd_switch2
            print *, "Set options%amd_switch2 = ", options%amd_switch2
         case("--metis")
            with_metis = .true.
            print *, "MeTiS run requested"
         case("--nond")
            with_nd = .false.
            print *, "ND run disabled"
         case("--reord=1")
            options%reord = 1
            print *, "Set Jonathan's preprocessing ordering"
         case("--reord=2")
            options%reord = 2
            print *, "Set Sue's preprocessing ordering"
         case("--coarse-partition-method")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%coarse_partition_method
            print *, "Set options%coarse_partition_method = ", &
               options%coarse_partition_method
         case("--matching")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%matching
            print *, "Set options%matching = ", &
               options%matching
         case("--print-level")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) options%print_level
            print *, "Set options%print_level = ", &
               options%print_level
         case("--randomize")
            call get_command_argument(argnum, argval)
            argnum = argnum + 1
            read( argval, * ) random
            print *, "Randomizing matrix row order, seed = ", random
         case default
            print *, "Unrecognised command line argument: ", argval
            stop
         end select
      end do
   end subroutine proc_args

   subroutine randomize_list(n, list, state)
      integer, intent(in) :: n
      integer, dimension(n), intent(inout) :: list
      type(random_state), intent(inout) :: state

      integer :: i, idx1, idx2, temp

      ! do n random swaps
      do i = 1, n
         idx1 = random_integer(state, n)
         idx2 = random_integer(state, n)
         temp = list(idx1)
         list(idx1) = list(idx2)
         list(idx2) = temp
      end do
   end subroutine randomize_list

   subroutine randomize_matrix(n, ptr, row, seed)
      integer, intent(in) :: n
      integer, dimension(n+1), intent(in) :: ptr
      integer, dimension(ptr(n+1)-1), intent(inout) :: row
      integer, intent(in) :: seed

      integer :: i
      type(random_state) :: state

      call random_set_seed(state, seed)
      do i = 1, n
         call randomize_list(ptr(i+1)-ptr(i), row(ptr(i)), state)
      end do
   end subroutine randomize_matrix

   subroutine calculate_stats(n, ptr, row, perm, nfact, nflops)
      integer, intent(in) :: n
      integer, dimension(n+1), intent(in) :: ptr
      integer, dimension(ptr(n+1)-1), intent(in) :: row
      integer, dimension(n), intent(in) :: perm
      integer(long), intent(out) :: nfact
      integer(long), intent(out) :: nflops

      integer :: i, realn, st
      integer, dimension(:), allocatable :: perm2, invp, parent, cc
      integer, dimension(:), allocatable :: sptr, ptr2, row2, iw

      ! Expand to a full matrix
      allocate(ptr2(n+1), row2(2*ptr(n+1)), iw(n), sptr(n+1))
      ptr2(1:n+1) = ptr(1:n+1)
      row2(1:ptr(n+1)-1) = row(1:ptr(n+1)-1)
      call half_to_full(n, row2, ptr2, iw)

      ! Limited analyse phase nemin=1
      allocate(parent(n), invp(n), perm2(n), cc(n+1))
      perm2(:) = perm(:)
      do i = 1, n
         invp(perm(i)) = i
         sptr(i) = i
      end do
      sptr(n+1) = n+1
      call find_etree(n, ptr2, row2, perm2, invp, parent, st)
      if(st.ne.0) goto 10
      call find_postorder(n, realn, ptr2, perm2, invp, parent, st)
      if(st.ne.0) goto 10
      call find_col_counts(n, ptr2, row2, perm2, invp, parent, cc, st)
      if(st.ne.0) goto 10
      call calc_stats(n, sptr, cc, nfact=nfact, nflops=nflops)

      return

      10 continue
      print *, "Allocation error in finding stats"
   end subroutine calculate_stats

end program
