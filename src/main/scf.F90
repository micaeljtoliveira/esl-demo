module esl_scf_m

  use prec, only : dp,ip
  use fdf, only : fdf_get
  
#ifdef WITH_FLOOK
  use esl_flook_global_m, only: LUA
  use dictionary
  use esl_dict_m
  use esl_flook_if_m
#endif

  use esl_basis_m
  use esl_density_m
  use esl_grid_m
  use esl_hamiltonian_m
  use esl_mixing_m
  use esl_potential_m
  use esl_states_m
  use esl_system_m

  ! AC-related functions
  use esl_sparse_pattern_m, only: sparse_pattern_t
  use esl_create_sparse_pattern_ac_m, only: create_sparse_pattern_ac_create
  use esl_overlap_matrix_ac_m, only: overlap_matrix_ac_calculate
  use esl_density_matrix_ac_m, only: density_matrix_ac_next

  implicit none
  private

  public :: scf_t

  !Data structure containing the data for the SCF
  type scf_t
    
    real(dp) :: tol_reldens !< Tolerance for SCF convergence
    integer(ip) :: max_iter !< Maximum number of iterations

    !< Mixer used during the SCF cycle
    type(mixing_t) :: mixer

    !< Density in/out
    type(density_t) :: rho_in, rho_out

    !< Hamiltonian/Potential in/out
    type(hamiltonian_t) :: H

  contains
    private
    procedure, public :: init
    procedure, public :: mix
    
    procedure, public :: loop

    final :: cleanup
  end type scf_t

contains


  !< Initialize density and wfn
  !<
  !< Atomic-Centered orbitals does the following things:
  !< 1. Initialize the sparse pattern by determining couplings based
  !<    purely on the inter-orbital ranges. There will only be
  !<    matrix elements if the distance between two atomic centered
  !<    orbitals are within the sum of their cutoff radius.
  !< 2. Once the sparse pattern has been created we calculate the overlap
  !<    matrix which is fixed for the entirety of the SCF loop.
  !< 3. Finally the Hamiltonian is initialized (an initialization
  !<    of the Hamiltonian also creates the non-SCF matrix elements)
  subroutine init(this, system, states)
    class(scf_t) :: this 
    type(system_t), intent(inout) :: system
    type(states_t), intent(in) :: states

    this%tol_reldens = fdf_get('SCFTolerance',1.0e-6_dp)
    this%max_iter    = fdf_get('SCFMaxIterations', 100)

    call this%mixer%init()

    select case (system%basis%type)
    case ( PLANEWAVES )
      ! TODO anything syecific to SCF initialization
    case( ATOMCENTERED )
      ! Initialization of the SCF step is done here.
      call create_sparse_pattern_ac_create(system%basis%ac, system%sparse_pattern)

      ! Calculate the overlap matrix for this SCF cycle
      call overlap_matrix_ac_calculate(system%basis%ac, system%basis%grid, &
          system%sparse_pattern, system%S)

    end select

    ! This is necessary for both AC and PW
    ! AC only needs the potential class (TODO consider moving the potential_t somewhere else!)
    call this%H%init(system%basis, system%geo, states, &
        system%sparse_pattern, &
        periodic=.false.)

    ! Finally we can initialize the densities
    ! This *has* to be done in the end because the density matrices
    ! for AC requires the sparse pattern to be updated.!
    call this%rho_in%init(system)
    call this%rho_out%init(system)

#ifdef WITH_FLOOK
    call esl_dict_var_add('SCF.Mixer.Alpha', this%mixer%alpha)
    call esl_dict_var_add('SCF.Iter.Max', this%max_iter)
    call esl_dict_var_add('SCF.Tolerance', this%tol_reldens)
#endif

  end subroutine init

  !Cleaning up
  !----------------------------------------------------
  subroutine cleanup(this)
    type(scf_t) :: this

  end subroutine cleanup

  !Perform the self-consistent field calculation
  !----------------------------------------------------
  subroutine loop(this, elsi, system, states, smear)
    use yaml_output
    use esl_smear_m
    use esl_states_m
    use esl_elsi_m

    class(scf_t), intent(inout) :: this
    type(elsi_t), intent(inout) :: elsi
    type(system_t), intent(inout) :: system
    type(states_t), intent(inout) :: states
    type(smear_t), intent(inout) :: smear

    integer :: iter !< Interation
    real(dp) :: res

#ifdef WITH_FLOOK
    call esl_dict_var_add('SCF.Residue', res)
#endif

    ! Perform initial guess on the density
    call this%rho_in%guess(system)
    
    !Calc. potentials from guess density
    select case (system%basis%type)
    case ( PLANEWAVES )
      call this%H%potential%calculate(this%rho_in%density_pw%density, system%energy)
    case( ATOMCENTERED )
      ! We do not need to initialize any values for the guessed density
    end select

    ! TODO 
    ! Randomize the states
    ! Generally these are not needed for AC since we diagonalize
    ! the Hamiltonian. However, when AC is using order-N methods one
    ! does require initial guesses for the states.
    call states%randomize()

    call yaml_mapping_open("SCF cycle")

    loop_scf: do iter = 1, this%max_iter
      call yaml_map("Iteration", iter)

      ! Diagonalization (ELSI/KSsolver)
      call this%H%eigensolver(system%basis, states)

      ! Update occupations
      call smear%calc_fermi_occ(elsi, states)

      ! Calculate density
      call this%rho_in%calculate(elsi, system, this%H, states, out=this%rho_out)
      
      ! Calculate necessary potentials
      select case (system%basis%type)
      case ( PLANEWAVES )

        call this%H%potential%calculate(this%rho_out%density_pw%density, system%energy)
        
      case( ATOMCENTERED )

        ! TODO, clarify intent here. The potentials are required to calculate the
        ! output density. As such the potential type is required in the density_ac%calculate
        ! routine.
        
      end select

      !Calc. energies
      call system%energy%calculate(states)  

      !Test tolerance and print status
      !We use rhonew to compute the relative density
      ! TODO fix the pw/ac part due to the number of states. They are behaving
      !      differently, so perhaps it is better to pass everything?
      !      For now I don't do this...
      res = this%rho_in%residue(system%basis, this%rho_out, states)
      call yaml_map("Residue", res)

#ifdef WITH_FLOOK
      ! Exchange data with Lua, so
      ! Call lua just before we are to initialize a new step.
      call flook_if_call(LUA, LUA_SCF_LOOP)
#endif

      if ( res <= this%tol_reldens ) then
        call yaml_comment("SCF cycle converged.")
        
        exit loop_scf
        
      end if

      ! Perform mixing (in/out)
      call this%mix(system%basis, this%rho_in, this%rho_out)

    end do loop_scf
    
    call yaml_mapping_close()

    call system%energy%display()

  end subroutine loop
  
  ! Perform mixing step
  !----------------------------------------------------
  subroutine mix(this, basis, in, out)
    class(scf_t) :: this
    type(basis_t),  intent(in)   :: basis
    type(density_t), intent(inout) :: in, out 

    real(kind=dp), allocatable :: next(:)
    integer :: np

    select case ( basis%type )
    case ( PLANEWAVES )

      np = in%np

      allocate(next(1:np))
      call this%mixer%linear(np, in%density_pw%density(1:np), out%density_pw%density(1:np), next(1:np))
      call in%density_pw%set_den(next)
      deallocate(next)
      
    case ( ATOMCENTERED )

      ! Since the linear mixing does not do look-ahead calls we can alias
      ! the same array
      np = in%ac%DM%sp%nz
      call this%mixer%linear(np, in%ac%DM%M, out%ac%DM%M, in%ac%DM%M)
      
    end select

  end subroutine mix

end module esl_scf_m
